import Foundation

/// Model providers. Phase 1 implements Anthropic and Ollama; OpenAI-compatible,
/// LM Studio and Apple on-device are added in later phases.
public enum ProviderKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case anthropic
    case ollama

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .ollama: "Ollama (local)"
        }
    }

    /// Local providers never send content off this Mac.
    public var isLocal: Bool {
        switch self {
        case .anthropic: false
        case .ollama: true
        }
    }

    /// Keychain account name for providers that need an API key.
    public var keychainAccount: String? {
        switch self {
        case .anthropic: "anthropic"
        case .ollama: nil
        }
    }

    public var suggestedModels: [String] {
        switch self {
        case .anthropic: ["claude-opus-5-5", "claude-sonnet-5-5"]
        case .ollama: []
        }
    }
}

/// What the assistant is being used for; each task can use a different model.
public enum AssistantTask: String, Codable, CaseIterable, Sendable, Identifiable {
    case planning
    case writing
    case building
    case quickCommands

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .planning: "Planning"
        case .writing: "Writing"
        case .building: "Building"
        case .quickCommands: "Quick commands"
        }
    }
}

public struct ModelSelection: Codable, Hashable, Sendable {
    public var provider: ProviderKind
    public var model: String

    public init(provider: ProviderKind, model: String) {
        self.provider = provider
        self.model = model
    }
}

/// Non-secret settings, persisted as JSON in UserDefaults.
public struct AppSettings: Codable, Hashable, Sendable {
    public var planning: ModelSelection
    public var writing: ModelSelection
    /// The builder agent (prototypes and HTML decks).
    public var building: ModelSelection
    public var quickCommands: ModelSelection
    /// The task the chat currently runs as.
    public var activeTask: AssistantTask
    public var anthropicBaseURL: String
    /// `output_config.effort` for Anthropic requests: low, medium, high, xhigh, max.
    public var anthropicEffort: String
    public var ollamaBaseURL: String
    public var maxOutputTokens: Int
    /// Send voice messages as soon as you stop talking (otherwise they go into the composer).
    public var voiceAutoSend: Bool
    /// Keep a timestamped log of each session (messages, agent steps, voice audio) in ~/Movies/Snazzy Pro/Sessions.
    public var recordSessions: Bool
    /// Cloud providers the user has agreed to send content to (App Store 5.1.2).
    public var cloudConsent: [String] = []

    public static let `default` = AppSettings(
        planning: ModelSelection(provider: .anthropic, model: "claude-opus-5-5"),
        writing: ModelSelection(provider: .anthropic, model: "claude-opus-5-5"),
        building: ModelSelection(provider: .anthropic, model: "claude-opus-5-5"),
        quickCommands: ModelSelection(provider: .anthropic, model: "claude-sonnet-5-5"),
        activeTask: .planning,
        anthropicBaseURL: "https://api.anthropic.com",
        anthropicEffort: "medium",
        ollamaBaseURL: "http://localhost:11434",
        maxOutputTokens: 32_000,
        voiceAutoSend: false,
        recordSessions: true
    )

    public init(
        planning: ModelSelection, writing: ModelSelection, building: ModelSelection, quickCommands: ModelSelection,
        activeTask: AssistantTask, anthropicBaseURL: String, anthropicEffort: String,
        ollamaBaseURL: String, maxOutputTokens: Int, voiceAutoSend: Bool, recordSessions: Bool
    ) {
        self.planning = planning
        self.writing = writing
        self.building = building
        self.voiceAutoSend = voiceAutoSend
        self.recordSessions = recordSessions
        self.quickCommands = quickCommands
        self.activeTask = activeTask
        self.anthropicBaseURL = anthropicBaseURL
        self.anthropicEffort = anthropicEffort
        self.ollamaBaseURL = ollamaBaseURL
        self.maxOutputTokens = maxOutputTokens
    }

    // Tolerant decoding: fields added in later versions fall back to defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings.default
        planning = try c.decodeIfPresent(ModelSelection.self, forKey: .planning) ?? d.planning
        writing = try c.decodeIfPresent(ModelSelection.self, forKey: .writing) ?? d.writing
        building = try c.decodeIfPresent(ModelSelection.self, forKey: .building) ?? d.building
        voiceAutoSend = try c.decodeIfPresent(Bool.self, forKey: .voiceAutoSend) ?? d.voiceAutoSend
        recordSessions = try c.decodeIfPresent(Bool.self, forKey: .recordSessions) ?? d.recordSessions
        cloudConsent = try c.decodeIfPresent([String].self, forKey: .cloudConsent) ?? []
        quickCommands = try c.decodeIfPresent(ModelSelection.self, forKey: .quickCommands) ?? d.quickCommands
        activeTask = try c.decodeIfPresent(AssistantTask.self, forKey: .activeTask) ?? d.activeTask
        anthropicBaseURL = try c.decodeIfPresent(String.self, forKey: .anthropicBaseURL) ?? d.anthropicBaseURL
        anthropicEffort = try c.decodeIfPresent(String.self, forKey: .anthropicEffort) ?? d.anthropicEffort
        ollamaBaseURL = try c.decodeIfPresent(String.self, forKey: .ollamaBaseURL) ?? d.ollamaBaseURL
        maxOutputTokens = try c.decodeIfPresent(Int.self, forKey: .maxOutputTokens) ?? d.maxOutputTokens
    }

    public func selection(for task: AssistantTask) -> ModelSelection {
        switch task {
        case .planning: planning
        case .writing: writing
        case .building: building
        case .quickCommands: quickCommands
        }
    }

    public mutating func setSelection(_ selection: ModelSelection, for task: AssistantTask) {
        switch task {
        case .planning: planning = selection
        case .writing: writing = selection
        case .building: building = selection
        case .quickCommands: quickCommands = selection
        }
    }
}

/// Loads and saves `AppSettings`. Secrets are not part of this store.
public struct SettingsStore: Sendable {
    public static let key = "SnazzyPro.settings.v1"
    private let suiteName: String?

    public init(suiteName: String? = nil) { self.suiteName = suiteName }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    public func load() -> AppSettings {
        guard let data = defaults.data(forKey: Self.key) else { return .default }
        do {
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            Log.settings.error("Settings unreadable, using defaults: \(error.localizedDescription, privacy: .public)")
            return .default
        }
    }

    public func save(_ settings: AppSettings) {
        do {
            defaults.set(try JSONEncoder().encode(settings), forKey: Self.key)
        } catch {
            Log.settings.error("Could not save settings: \(error.localizedDescription, privacy: .public)")
        }
    }
}
