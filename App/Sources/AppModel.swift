import Assistant
import Builder
import CaptureEngine
import Foundation
import Network
import Observation
import SnazzyCore

/// App-wide state: settings, secrets, connectivity and the chat.
@MainActor @Observable
final class AppModel {
    var settings: AppSettings {
        didSet { if settings != oldValue { settingsStore.save(settings) } }
    }
    /// Providers that have an API key in the Keychain (cached; the Keychain
    /// itself is only read when a provider is created).
    private(set) var storedKeys: Set<ProviderKind> = []
    private(set) var isOnline = true
    /// Models discovered from each provider (via Test / Refresh).
    var discoveredModels: [ProviderKind: [ModelInfo]] = [:]

    let secrets: any SecretStore
    private let settingsStore: SettingsStore
    private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private(set) var chat: ChatSession!
    let capture: CaptureController
    let builder: BuilderController
    @ObservationIgnored private(set) var presets: PresetController!
    @ObservationIgnored private(set) var mcp: MCPManager!
    @ObservationIgnored private(set) var developer: DeveloperController!
    @ObservationIgnored private(set) var sharing: SharingController!
    @ObservationIgnored private(set) var live: LiveController!
    @ObservationIgnored private(set) var broadcast: BroadcastController!
    @ObservationIgnored private(set) var remote: RemoteController!
    /// Set by the headless self-test so it never writes into the user's session logs.
    var sessionLoggingSuspended = false
    /// Hides the conversation list (tours, screen sharing).
    var hideConversations = false
    /// The Slides tab's mode (nil: Present when a deck is open, else samples).
    var slidesMode: SlidesPanel.Mode?
    /// Asks the Live tab to scroll to a section ("broadcast" or "top").
    var liveScrollTarget: String?
    /// The right-hand panel's tab (the builder switches to it when it works).
    var sidePanelTab: SidePanel.Tab = SidePanel.Tab(rawValue: UserDefaults.standard.string(forKey: "SnazzyPro.sidePanelTab") ?? "") ?? .builder {
        didSet { UserDefaults.standard.set(sidePanelTab.rawValue, forKey: "SnazzyPro.sidePanelTab") }
    }

    init(secrets: any SecretStore = KeychainStore(), settingsStore: SettingsStore = SettingsStore()) {
        self.secrets = secrets
        self.settingsStore = settingsStore
        var initial = settingsStore.load()
        // First launch: if Apple's on-device model is available, use it for every
        // task, so the assistant works with no key, no Ollama and no network.
        if !settingsStore.hasSaved, AppleOnDeviceProvider.isAvailable {
            let apple = ModelSelection(provider: .appleOnDevice, model: ProviderKind.appleModelID)
            for task in AssistantTask.allCases { initial.setSelection(apple, for: task) }
        }
        self.settings = initial
        self.capture = CaptureController()
        self.builder = BuilderController()
        self.chat = ChatSession(app: self)
        self.presets = PresetController(app: self)
        self.mcp = MCPManager(app: self, secrets: secrets)
        self.developer = DeveloperController(app: self)
        self.sharing = SharingController(app: self)
        self.live = LiveController(app: self)
        self.broadcast = BroadcastController(app: self)
        self.remote = RemoteController(app: self)
        refreshStoredKeys()
        startPathMonitor()
        mcp.start()
        builder.onActivity = { [weak self] in self?.sidePanelTab = .builder }
        capture.onRecordingSaved = { [weak self] in self?.developer.refresh() }
        capture.onRecordingEvent = { [weak self] type, fields in
            guard let self else { return }
            chat.logSession(type, fields)
            // The first chapter is the slide showing when recording starts.
            if type == "recording_started", capture.setup.source == .slides, builder.isDeckOpen {
                let i = builder.currentSlide
                markSlide(i, builder.deckSlides.indices.contains(i) ? builder.deckSlides[i] : nil)
            }
        }
        builder.onPopOut = { [weak self] in
            guard let self else { return }
            Task { await self.capture.screen.setIncludedOwnWindows(self.capture.ownWindowsToInclude()) }
        }
        capture.ownWindowsToInclude = { [weak self] in
            self?.builder.popOutWindowNumber.map { [UInt32($0)] } ?? []
        }
        // Slides: the deck's Present window is what gets recorded.
        capture.slidesStage = { [weak self] in self?.builder.stage }
        capture.prepareSlidesStage = { [weak self] in
            guard let self else { return nil }
            guard builder.current?.kind == .presentation else {
                return "Open a slide deck in the Builder first (or pick one in the Slides tab)."
            }
            if builder.stage == nil { builder.openPopOut() }
            builder.setStageLocked(true)
            return nil
        }
        capture.releaseSlidesStage = { [weak self] in self?.builder.setStageLocked(false) }
        builder.onStageChange = { [weak self] in
            guard let self, capture.setup.source == .slides else { return }
            Task { await self.capture.updateScreenFeed() }
        }
        builder.onSlideChange = { [weak self] index, slide in
            guard let self else { return }
            markSlide(index, slide)
            live.publishStatus()
            chat.logSession("slide", ["index": .number(Double(index)), "title": .string(slide?.displayTitle ?? "")])
        }
        builder.onStep = { [weak self] step in
            self?.chat.logSession("builder", ["text": .string(step.text)])
        }
        Log.app.info("Snazzy Pro started")
    }

    /// Notes a slide change in the recording (becomes a chapter).
    private func markSlide(_ index: Int, _ slide: BuilderController.DeckSlide?) {
        capture.recorder.mark(["type": "slide", "index": .number(Double(index)),
                               "title": .string(slide?.displayTitle ?? "Slide \(index + 1)")])
    }

    var activeSelection: ModelSelection { settings.selection(for: settings.activeTask) }

    // MARK: Keys

    func refreshStoredKeys() {
        storedKeys = Set(ProviderKind.allCases.filter { kind in
            guard let account = kind.keychainAccount else { return false }
            return ((try? secrets.secret(for: account)) ?? nil)?.isEmpty == false
        })
    }

    func saveAPIKey(_ key: String, for provider: ProviderKind) throws {
        guard let account = provider.keychainAccount else { return }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try secrets.setSecret(trimmed, for: account)
        refreshStoredKeys()
    }

    func deleteAPIKey(for provider: ProviderKind) throws {
        guard let account = provider.keychainAccount else { return }
        try secrets.deleteSecret(for: account)
        refreshStoredKeys()
    }

    // MARK: Providers

    func makeProvider(_ kind: ProviderKind) throws -> any ModelProvider {
        switch kind {
        case .anthropic:
            let key = try secrets.secret(for: "anthropic") ?? ""
            return try AnthropicProvider(apiKey: key, baseURL: settings.anthropicBaseURL)
        case .ollama:
            return try OllamaProvider(baseURL: settings.ollamaBaseURL)
        case .appleOnDevice:
            return try AppleOnDeviceProvider()
        }
    }

    /// Why a provider can't be used right now, if it can't.
    func unavailableReason(_ kind: ProviderKind) -> String? {
        if kind == .appleOnDevice { return AppleOnDeviceProvider.unavailableReason }
        if !kind.isLocal && !isOnline { return "Offline: cloud models are unavailable. Local models still work." }
        if kind.keychainAccount != nil && !storedKeys.contains(kind) {
            return "No \(kind.displayName) API key. Add one in Settings."
        }
        return nil
    }

    /// Lists models; used by "Test connection" and to fill model pickers.
    func testConnection(_ kind: ProviderKind) async -> Result<[ModelInfo], Error> {
        do {
            let models = try await makeProvider(kind).listModels()
            discoveredModels[kind] = models
            return .success(models)
        } catch {
            return .failure(error)
        }
    }

    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.isOnline != online else { return }
                self.isOnline = online
                Log.app.notice("Network \(online ? "online" : "offline", privacy: .public)")
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.snazzy.pro.network"))
    }

    // MARK: Assistant tools

    /// The app's actions as assistant tools. Each one calls the same method the
    /// UI uses and returns the new state.
    /// The tools for a chat turn answered by `provider`.
    func makeToolRegistry(for provider: ProviderKind) -> ToolRegistry {
        AssistantTools.registry(app: self, offMac: provider.isLocal ? nil : provider.displayName)
    }

    func modelsJSON() async -> JSONValue {
        var providers: [String: JSONValue] = [:]
        for kind in ProviderKind.allCases {
            if let reason = unavailableReason(kind) {
                providers[kind.rawValue] = ["available": false, "reason": .string(reason), "local": .bool(kind.isLocal),
                                            "suggested": .array(kind.suggestedModels.map { .string($0) })]
                continue
            }
            switch await testConnection(kind) {
            case .success(let models):
                providers[kind.rawValue] = ["available": true, "local": .bool(kind.isLocal),
                    "models": .array(models.prefix(40).map { ["id": .string($0.id), "tools": $0.supportsTools.map(JSONValue.bool) ?? .null] })]
            case .failure(let error):
                providers[kind.rawValue] = ["available": false, "reason": .string(error.localizedDescription), "local": .bool(kind.isLocal)]
            }
        }
        return ["providers": .object(providers), "active_task": .string(settings.activeTask.rawValue),
                "tasks": .object(Dictionary(uniqueKeysWithValues: AssistantTask.allCases.map { task in
                    let s = settings.selection(for: task)
                    return (task.rawValue, ["provider": .string(s.provider.rawValue), "model": .string(s.model)] as JSONValue)
                }))]
    }

    func setModel(task: String, provider: String, model: String, makeActive: Bool) async throws -> JSONValue {
        guard let task = AssistantTask(rawValue: task) else { throw CaptureActionError(message: "Unknown task \(task)") }
        guard let kind = ProviderKind(rawValue: provider) else { throw CaptureActionError(message: "Unknown provider \(provider)") }
        if kind == .ollama, case .success(let models) = await testConnection(.ollama), !models.contains(where: { $0.id == model }) {
            throw CaptureActionError(message: "Ollama has no model \(model). Installed: " + models.map(\.id).joined(separator: ", "))
        }
        settings.setSelection(ModelSelection(provider: kind, model: model), for: task)
        if makeActive { settings.activeTask = task }
        var result: [String: JSONValue] = ["task": .string(task.rawValue), "provider": .string(kind.rawValue), "model": .string(model),
                                           "active_task": .string(settings.activeTask.rawValue),
                                           "note": "Takes effect from the next message."]
        if let reason = unavailableReason(kind) { result["warning"] = .string(reason) }
        return .object(result)
    }

    /// Everything the assistant can know about Snazzy Pro's settings (no secrets).
    func settingsJSON() -> JSONValue {
        [
            "active_task": .string(settings.activeTask.rawValue),
            "models": .object(Dictionary(uniqueKeysWithValues: AssistantTask.allCases.map { task in
                let s = settings.selection(for: task)
                return (task.rawValue, ["provider": .string(s.provider.rawValue), "model": .string(s.model), "local": .bool(s.provider.isLocal)] as JSONValue)
            })),
            "anthropic": ["effort": .string(settings.anthropicEffort), "base_url": .string(settings.anthropicBaseURL),
                          "api_key": .string(storedKeys.contains(.anthropic) ? "stored in Keychain" : "missing")],
            "ollama": ["base_url": .string(settings.ollamaBaseURL)],
            "max_output_tokens": .number(Double(settings.maxOutputTokens)),
            "voice": ["auto_send": .bool(settings.voiceAutoSend), "microphone": .string(capture.setup.mic?.name ?? "system default")],
            "session_record": ["enabled": .bool(settings.recordSessions), "folder": "~/Movies/Snazzy Pro/Sessions"],
            "recordings_folder": "~/Movies/Snazzy Pro/Recordings",
            "capture": capture.stateJSON(),
            "presets": presets.listJSON(),
            "online": .bool(isOnline),
        ]
    }

    /// Changes app options (not models or capture; those have their own tools).
    func updateOptions(voiceAutoSend: Bool?, recordSessions: Bool?, effort: String?, maxOutputTokens: Int?) -> JSONValue {
        if let voiceAutoSend { settings.voiceAutoSend = voiceAutoSend }
        if let recordSessions { settings.recordSessions = recordSessions }
        if let effort { settings.anthropicEffort = effort }
        if let maxOutputTokens { settings.maxOutputTokens = min(max(maxOutputTokens, 4_000), 128_000) }
        return settingsJSON()
    }

    func projectState() -> JSONValue {
        let selection = activeSelection
        return [
            "app": "Snazzy Pro",
            "build_phase": 4,
            "assistant": [
                "task": .string(settings.activeTask.rawValue),
                "provider": .string(selection.provider.rawValue),
                "model": .string(selection.model),
                "local": .bool(selection.provider.isLocal),
            ],
            "online": .bool(isOnline),
            "capture": capture.stateJSON(),
            "builder": builder.stateJSON(),
            "active_preset": presets.activeName.map(JSONValue.string) ?? .null,
            "model_settings": .object(Dictionary(uniqueKeysWithValues: AssistantTask.allCases.map { task in
                let s = settings.selection(for: task)
                return (task.rawValue, ["provider": .string(s.provider.rawValue), "model": .string(s.model)] as JSONValue)
            })),
            "slides": [],
            "recording": capture.recordingJSON(),
        ]
    }
}
