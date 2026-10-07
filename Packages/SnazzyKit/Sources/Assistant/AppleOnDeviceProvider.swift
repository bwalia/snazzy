import Foundation
import SnazzyCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Intelligence's on-device model via FoundationModels (macOS 26+).
/// No API key, no network, nothing leaves the Mac.
///
/// The framework runs tools inside its own loop, so tools are executed through
/// `ModelRequest.toolExecutor` (the conversation runner's validation and
/// confirmation). The context window is small, so the provider sends a
/// condensed history and only as many tools as fit.
public struct AppleOnDeviceProvider: ModelProvider {
    public let kind = ProviderKind.appleOnDevice

    public init() throws {
        if let reason = Self.unavailableReason { throw ProviderError.unreachable(reason) }
    }

    /// Why the on-device model can't be used, or nil if it can.
    public static var unavailableReason: String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return "Apple Intelligence models need macOS 26 or later." }
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This Mac can't run Apple Intelligence models."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings to use the on-device model."
        case .unavailable(.modelNotReady):
            return "The on-device model is still downloading. Try again in a few minutes."
        case .unavailable:
            return "The on-device model isn't available right now."
        }
        #else
        return "Apple Intelligence models aren't available in this build."
        #endif
    }

    public static var isAvailable: Bool { unavailableReason == nil }

    public func listModels() async throws -> [ModelInfo] {
        [ModelInfo(id: ProviderKind.appleModelID, displayName: "Apple Intelligence (on-device)", supportsTools: true)]
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return AppleSession.stream(request)
        }
        #endif
        return AsyncThrowingStream { $0.finish(throwing: ProviderError.unreachable(Self.unavailableReason ?? "Unavailable")) }
    }

    // MARK: Prompt building (platform-independent, unit-tested)

    /// The conversation before the latest user message, as compact text,
    /// newest turns kept, within `budget` characters.
    static func condensedHistory(_ messages: [ChatMessage], budget: Int) -> String {
        var lines: [String] = []
        for m in messages {
            switch m.role {
            case .user:
                let text = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { lines.append("User: \(text)") }
            case .assistant:
                let text = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let tools = m.toolCalls.map(\.name)
                if !tools.isEmpty { lines.append("Assistant used: \(tools.joined(separator: ", "))") }
                if !text.isEmpty { lines.append("Assistant: \(text)") }
            case .tool:
                continue
            }
        }
        var kept: [String] = []
        var used = 0
        for line in lines.reversed() {
            let clipped = line.count > 500 ? String(line.prefix(497)) + "…" : line
            if used + clipped.count > budget { break }
            kept.insert(clipped, at: 0)
            used += clipped.count + 1
        }
        return kept.joined(separator: "\n")
    }

    /// The latest user turn as a prompt (images can't be sent to this model).
    static func prompt(from messages: [ChatMessage]) -> String {
        guard let last = messages.last(where: { $0.role == .user }) else { return "" }
        var text = last.text
        if !last.images.isEmpty { text += "\n(The user attached \(last.images.count) image(s); the on-device model can't see images.)" }
        return text
    }

    /// Tool results are clipped so they don't fill the small context.
    static func clip(_ s: String, to limit: Int = 1400) -> String {
        s.count > limit ? String(s.prefix(limit)) + "… (truncated)" : s
    }

    /// Shrinks a JSON tool result for the small model: drops IDs (tools take
    /// names), nulls and empty values, then clips. Non-JSON is just clipped.
    static func compactResult(_ content: String) -> String {
        guard let json = try? JSONValue.parse(content) else { return clip(content) }
        func strip(_ v: JSONValue) -> JSONValue? {
            switch v {
            case .null: return nil
            case .string(let s): return s.isEmpty ? nil : v
            case .array(let a):
                let items = a.compactMap(strip)
                return items.isEmpty ? nil : .array(items)
            case .object(let o):
                var out: [String: JSONValue] = [:]
                for (k, val) in o where k != "id" && !k.hasSuffix("_id") && k != "note" {
                    if let s = strip(val) { out[k] = s }
                }
                return out.isEmpty ? nil : .object(out)
            default: return v
            }
        }
        return clip((strip(json) ?? json).compactString)
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
enum AppleSession {
    static func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let message = try await run(request, continuation: continuation, compact: false)
                    continuation.yield(message)
                    continuation.finish()
                } catch let error as LanguageModelSession.GenerationError {
                    if case .exceededContextWindowSize = error, !Task.isCancelled {
                        // Retry once with no history and fewer tools.
                        do {
                            let message = try await run(request, continuation: continuation, compact: true)
                            continuation.yield(message)
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: describe(error))
                        }
                    } else {
                        continuation.finish(throwing: describe(error))
                    }
                } catch {
                    continuation.finish(throwing: describe(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func run(_ request: ModelRequest, continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation,
                            compact: Bool) async throws -> StreamEvent {
        let model = SystemLanguageModel.default
        let context = max(model.contextSize, 4096)
        let history = compact ? "" : AppleOnDeviceProvider.condensedHistory(
            Array(request.messages.dropLast()), budget: context / 3)
        var instructions = request.system ?? "You are a helpful assistant."
        if !history.isEmpty { instructions += "\n\nConversation so far:\n\(history)" }

        let tools = try await fittingTools(request, model: model, budget: compact ? context / 5 : context * 2 / 5)
        let session = LanguageModelSession(model: model, tools: tools, instructions: instructions)
        let prompt = AppleOnDeviceProvider.prompt(from: request.messages)
        Log.provider.notice("Apple on-device request: \(tools.count) tools, history \(history.count) chars, context \(context)")

        var text = ""
        for try await snapshot in session.streamResponse(to: prompt) {
            let content = snapshot.content
            if content.count > text.count, content.hasPrefix(text) {
                continuation.yield(.textDelta(String(content.dropFirst(text.count))))
            }
            text = content
        }
        let message = ChatMessage(role: .assistant, parts: text.isEmpty ? [] : [.text(text)])
        return .completed(message: message, stopReason: .endTurn, usage: TokenUsage(), servedBy: ProviderKind.appleModelID)
    }

    /// Tools in priority order, dropped from the end until their schemas fit the budget.
    private static func fittingTools(_ request: ModelRequest, model: SystemLanguageModel, budget: Int) async throws -> [any Tool] {
        guard let executor = request.toolExecutor else { return [] }
        let ordered = AppleToolPolicy.order(request.tools)
        var tools: [any Tool] = ordered.map { AppleTool(definition: $0, executor: executor) }
        while !tools.isEmpty {
            // Exact count on macOS 26.4+; otherwise a conservative estimate per tool.
            var cost = tools.count * 140
            if #available(macOS 26.4, *), let exact = try? await model.tokenCount(for: tools) { cost = exact }
            if cost <= budget { break }
            tools.removeLast()
        }
        return tools
    }

    private static func describe(_ error: Error) -> Error {
        if let e = error as? LanguageModelSession.GenerationError {
            switch e {
            case .exceededContextWindowSize:
                return ProviderError.api(type: "on-device", message: "That's more than the on-device model can hold at once. Start a new conversation, or switch to a larger model for this task.")
            case .guardrailViolation:
                return ProviderError.api(type: "on-device", message: "Apple's on-device model declined this request. Try rephrasing, or use another model.")
            case .assetsUnavailable:
                return ProviderError.unreachable("The on-device model isn't ready yet (it may still be downloading).")
            case .unsupportedLanguageOrLocale:
                return ProviderError.api(type: "on-device", message: "The on-device model doesn't support this language yet.")
            default:
                return ProviderError.api(type: "on-device", message: e.localizedDescription)
            }
        }
        return error
    }
}

/// One of the app's tools, exposed to FoundationModels with its JSON schema.
@available(macOS 26.0, *)
struct AppleTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let definition: ToolDefinition
    let executor: @Sendable (ToolCall) async -> ToolResult

    var name: String { definition.name }
    var description: String {
        let d = definition.description
        return d.count > 220 ? String(d.prefix(217)) + "…" : d
    }

    var parameters: GenerationSchema {
        (try? GenerationSchema(root: AppleSchema.convert(definition.inputSchema, name: definition.name), dependencies: []))
            ?? GeneratedContent.generationSchema
    }

    @concurrent func call(arguments: GeneratedContent) async throws -> String {
        let args = (try? JSONValue.parse(arguments.jsonString)) ?? [:]
        let call = ToolCall(id: "apple_\(UUID().uuidString.prefix(8))", name: definition.name, arguments: args)
        let result = await executor(call)
        return AppleOnDeviceProvider.compactResult(result.content)
    }
}

/// Converts the JSON Schema subset our tools use into a FoundationModels schema.
@available(macOS 26.0, *)
enum AppleSchema {
    static func convert(_ schema: JSONValue, name: String) -> DynamicGenerationSchema {
        let description = schema["description"]?.stringValue
        if let options = schema["enum"]?.arrayValue?.compactMap(\.stringValue), !options.isEmpty {
            return DynamicGenerationSchema(name: name, description: description, anyOf: options)
        }
        switch schema["type"]?.stringValue {
        case "object":
            let props = schema["properties"]?.objectValue ?? [:]
            let required = Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            let properties = props.keys.sorted().map { key in
                DynamicGenerationSchema.Property(
                    name: key, description: props[key]?["description"]?.stringValue,
                    schema: convert(props[key] ?? [:], name: "\(name)_\(key)"), isOptional: !required.contains(key))
            }
            return DynamicGenerationSchema(name: name, description: description, properties: properties)
        case "array":
            return DynamicGenerationSchema(arrayOf: convert(schema["items"] ?? ["type": "string"], name: "\(name)_item"),
                                           minimumElements: schema["minItems"]?.intValue, maximumElements: schema["maxItems"]?.intValue)
        case "integer":
            return DynamicGenerationSchema(type: Int.self)
        case "number":
            return DynamicGenerationSchema(type: Double.self)
        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)
        default:
            return DynamicGenerationSchema(type: String.self)
        }
    }
}
#endif

/// Which tools the small on-device model gets first.
enum AppleToolPolicy {
    static let priority = [
        "select_mic", "select_capture_source", "select_inset_device", "set_inset",
        "open_preview", "close_preview", "start_recording", "stop_recording", "pause_recording", "resume_recording",
        "load_preset", "save_preset", "list_presets", "list_devices", "get_project_state",
        "create_project", "write_file", "check_preview", "show_slide", "update_settings", "set_model",
    ]

    static func order(_ tools: [ToolDefinition]) -> [ToolDefinition] {
        let rank = Dictionary(uniqueKeysWithValues: priority.enumerated().map { ($1, $0) })
        return tools.filter { rank[$0.name] != nil }.sorted { rank[$0.name]! < rank[$1.name]! }
    }
}
