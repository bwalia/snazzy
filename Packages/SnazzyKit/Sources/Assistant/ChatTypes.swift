import Foundation
import SnazzyCore

public enum ChatRole: String, Codable, Sendable {
    case user
    case assistant
    /// Tool results. Anthropic sends these as a user turn; Ollama as role "tool".
    case tool
}

public struct ToolCall: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var arguments: JSONValue

    public init(id: String, name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct ToolResult: Codable, Hashable, Sendable {
    public var callID: String
    public var name: String
    public var content: String
    public var isError: Bool

    public init(callID: String, name: String, content: String, isError: Bool = false) {
        self.callID = callID
        self.name = name
        self.content = content
        self.isError = isError
    }
}

public enum ContentPart: Codable, Hashable, Sendable {
    case text(String)
    case toolCall(ToolCall)
    case toolResult(ToolResult)
    /// A provider-specific block that must be echoed back unchanged to the
    /// same provider (e.g. Anthropic thinking blocks with signatures) and is
    /// dropped when the conversation is sent to a different provider.
    case opaque(provider: ProviderKind, block: JSONValue)
    /// An attached image (PNG/JPEG), sent to providers that accept images.
    case image(mediaType: String, data: Data)
}

public struct ChatMessage: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var role: ChatRole
    public var parts: [ContentPart]

    public init(id: UUID = UUID(), role: ChatRole, parts: [ContentPart]) {
        self.id = id
        self.role = role
        self.parts = parts
    }

    public static func user(_ text: String) -> ChatMessage { ChatMessage(role: .user, parts: [.text(text)]) }

    public var images: [(mediaType: String, data: Data)] {
        parts.compactMap { if case .image(let t, let d) = $0 { (t, d) } else { nil } }
    }

    public var text: String {
        parts.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined()
    }

    public var toolCalls: [ToolCall] {
        parts.compactMap { if case .toolCall(let c) = $0 { c } else { nil } }
    }
}

public struct ToolDefinition: Hashable, Sendable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct TokenUsage: Hashable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    public static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(inputTokens: a.inputTokens + b.inputTokens, outputTokens: a.outputTokens + b.outputTokens)
    }
}

public enum StopReason: Hashable, Sendable {
    case endTurn
    case toolUse
    case maxTokens
    case refusal
    case other(String)

    init(anthropic raw: String?) {
        switch raw {
        case "end_turn", "stop_sequence", nil: self = .endTurn
        case "tool_use": self = .toolUse
        case "max_tokens": self = .maxTokens
        case "refusal": self = .refusal
        case let other?: self = .other(other)
        }
    }
}

public struct ModelRequest: Sendable {
    public var model: String
    public var system: String?
    public var messages: [ChatMessage]
    public var tools: [ToolDefinition]
    public var maxTokens: Int
    /// Anthropic `output_config.effort`; ignored by providers without it.
    public var effort: String?
    /// For providers that run tools inside their own loop (Apple on-device):
    /// validates, confirms and runs a call exactly like the conversation runner.
    public var toolExecutor: (@Sendable (ToolCall) async -> ToolResult)?

    public init(
        model: String, system: String? = nil, messages: [ChatMessage], tools: [ToolDefinition] = [],
        maxTokens: Int = 32_000, effort: String? = nil
    ) {
        self.model = model
        self.system = system
        self.messages = messages
        self.tools = tools
        self.maxTokens = maxTokens
        self.effort = effort
    }
}

/// Events from one model turn. The turn always ends with `.completed`, which
/// carries the assembled assistant message (in block order) for the history.
public enum StreamEvent: Hashable, Sendable {
    case textDelta(String)
    case thinkingDelta(String)
    case toolCallStarted(name: String)
    /// A fragment of a tool call's JSON arguments as they stream (Anthropic),
    /// so the UI can show e.g. a file being written live.
    case toolInputDelta(callID: String, name: String, fragment: String)
    case completed(message: ChatMessage, stopReason: StopReason, usage: TokenUsage, servedBy: String?)
}

public struct ModelInfo: Hashable, Sendable, Identifiable {
    public var id: String
    public var displayName: String
    public var supportsTools: Bool?

    public init(id: String, displayName: String? = nil, supportsTools: Bool? = nil) {
        self.id = id
        self.displayName = displayName ?? id
        self.supportsTools = supportsTools
    }
}

public enum ProviderError: Error, LocalizedError, Equatable {
    case missingAPIKey(ProviderKind)
    case invalidBaseURL(String)
    case http(status: Int, message: String)
    case api(type: String, message: String)
    case unreachable(String)
    case malformedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let p): "No API key for \(p.displayName). Add one in Settings."
        case .invalidBaseURL(let u): "Invalid base URL: \(u)"
        case .http(let status, let message): "HTTP \(status): \(message)"
        case .api(let type, let message): "\(type): \(message)"
        case .unreachable(let message): message
        case .malformedResponse(let message): "Unexpected response: \(message)"
        }
    }
}
