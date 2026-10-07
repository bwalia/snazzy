import Assistant
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

    init(secrets: any SecretStore = KeychainStore(), settingsStore: SettingsStore = SettingsStore()) {
        self.secrets = secrets
        self.settingsStore = settingsStore
        self.settings = settingsStore.load()
        self.chat = ChatSession(app: self)
        refreshStoredKeys()
        startPathMonitor()
        Log.app.info("Snazzy Pro started")
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
        }
    }

    /// Why a provider can't be used right now, if it can't.
    func unavailableReason(_ kind: ProviderKind) -> String? {
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

    /// The app's actions as assistant tools. Phase 1 exposes project state only;
    /// device, slide and recording tools arrive with their phases.
    func makeToolRegistry() -> ToolRegistry {
        ToolRegistry([
            RegisteredTool(
                name: "get_project_state",
                description: "Get the current state of the Snazzy Pro project: active model, connectivity, slides, devices and recording status. Call this before making changes so you know what is set up.",
                inputSchema: ["type": "object", "properties": [:], "additionalProperties": false]
            ) { [weak self] _ in
                await MainActor.run { self?.projectState() ?? .null }
            },
        ])
    }

    func projectState() -> JSONValue {
        let selection = activeSelection
        return [
            "app": "Snazzy Pro",
            "build_phase": 1,
            "assistant": [
                "task": .string(settings.activeTask.rawValue),
                "provider": .string(selection.provider.rawValue),
                "model": .string(selection.model),
                "local": .bool(selection.provider.isLocal),
            ],
            "online": .bool(isOnline),
            "slides": [],
            "devices": "Device discovery is not available yet (phase 2).",
            "recording": "idle",
        ]
    }
}
