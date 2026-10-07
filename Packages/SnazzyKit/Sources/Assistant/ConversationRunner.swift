import Foundation
import SnazzyCore

/// Runs one user turn: streams the model, executes tool calls, feeds results
/// back, and repeats until the model stops calling tools.
///
/// Invalid tool calls get one retry with the validation error; a second
/// invalid round stops and asks the user. History is append-only (thinking
/// blocks stay valid).
public struct ConversationRunner: Sendable {
    public enum Event: Sendable {
        case textDelta(String)
        case thinkingDelta(String)
        case toolCallStarted(name: String)
        case toolInputDelta(callID: String, name: String, fragment: String)
        /// A tool is about to run (after validation).
        case toolRunning(ToolCall)
        /// A finished assistant message to append to the history.
        case assistantMessage(ChatMessage, stopReason: StopReason, servedBy: String?)
        case toolFinished(ToolCall, ToolResult)
        /// Tool results to append to the history.
        case toolResults(ChatMessage)
        case usage(TokenUsage)
        /// The loop stopped and needs the user (bad tool calls, refusal, truncation).
        case needsUser(String)
    }

    public var provider: any ModelProvider
    public var registry: ToolRegistry
    public var model: String
    public var system: String?
    public var maxTokens: Int
    public var effort: String?
    public var maxToolRounds: Int
    /// Asks the user to confirm a destructive tool call.
    public var confirm: @Sendable (ToolCall) async -> Bool

    public init(
        provider: any ModelProvider, registry: ToolRegistry, model: String, system: String? = nil,
        maxTokens: Int = 32_000, effort: String? = nil, maxToolRounds: Int = 12,
        confirm: @escaping @Sendable (ToolCall) async -> Bool = { _ in false }
    ) {
        self.provider = provider
        self.registry = registry
        self.model = model
        self.system = system
        self.maxTokens = maxTokens
        self.effort = effort
        self.maxToolRounds = maxToolRounds
        self.confirm = confirm
    }

    public func run(history: [ChatMessage]) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await loop(history: history) { @Sendable in continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func loop(history: [ChatMessage], emit: @escaping @Sendable (Event) -> Void) async throws {
        var messages = history
        var invalidRounds = 0

        for _ in 0..<maxToolRounds {
            try Task.checkCancellation()
            var request = ModelRequest(
                model: model, system: system, messages: messages, tools: registry.definitions,
                maxTokens: maxTokens, effort: effort)
            // Providers that run tools themselves (Apple on-device) use this, so
            // calls get the same validation, confirmation and UI events.
            let inline = InlineCalls()
            request.toolExecutor = { [registry, confirm] call in
                emit(.toolCallStarted(name: call.name))
                let errors = registry.validate(call)
                let result: ToolResult
                if !errors.isEmpty {
                    result = ToolRegistry.invalidResult(call, errors: errors, schema: registry.tool(named: call.name)?.definition.inputSchema)
                } else if registry.tool(named: call.name)?.requiresConfirmation == true, await !confirm(call) {
                    result = ToolResult(callID: call.id, name: call.name, content: "The user declined this action.", isError: true)
                } else {
                    emit(.toolRunning(call))
                    result = await registry.execute(call)
                }
                emit(.toolFinished(call, result))
                inline.append(call, result)
                return result
            }

            var completed: (ChatMessage, StopReason, TokenUsage, String?)?
            for try await event in provider.stream(request) {
                switch event {
                case .textDelta(let t): emit(.textDelta(t))
                case .thinkingDelta(let t): emit(.thinkingDelta(t))
                case .toolCallStarted(let name): emit(.toolCallStarted(name: name))
                case .toolInputDelta(let id, let name, let fragment): emit(.toolInputDelta(callID: id, name: name, fragment: fragment))
                case .completed(let message, let stop, let usage, let servedBy):
                    completed = (message, stop, usage, servedBy)
                }
            }
            guard let (assistant, stop, usage, servedBy) = completed else {
                throw ProviderError.malformedResponse("stream ended without a message")
            }
            // Record tools the provider ran itself in the usual call/result form,
            // so the history works with every provider.
            let ran = inline.all
            if !ran.isEmpty {
                let calls = ChatMessage(role: .assistant, parts: ran.map { .toolCall($0.0) })
                let results = ChatMessage(role: .tool, parts: ran.map { .toolResult($0.1) })
                messages.append(calls)
                messages.append(results)
                emit(.assistantMessage(calls, stopReason: .toolUse, servedBy: servedBy))
                emit(.toolResults(results))
            }
            messages.append(assistant)
            emit(.assistantMessage(assistant, stopReason: stop, servedBy: servedBy))
            emit(.usage(usage))

            let calls = assistant.toolCalls
            if calls.isEmpty {
                if stop == .refusal { emit(.needsUser("The model declined this request.")) }
                if stop == .maxTokens { emit(.needsUser("The reply hit the output limit and was cut off.")) }
                return
            }

            // A cut-off or refused turn can carry a partial tool call: never run it,
            // but answer every call so the history stays valid.
            if stop == .maxTokens || stop == .refusal {
                let reason = stop == .refusal ? "the model declined" : "the reply was cut off"
                let results = calls.map {
                    ToolResult(callID: $0.id, name: $0.name, content: "Not executed: \(reason).", isError: true)
                }
                let resultMessage = ChatMessage(role: .tool, parts: results.map(ContentPart.toolResult))
                emit(.toolResults(resultMessage))
                emit(.needsUser(stop == .refusal
                    ? "The model declined this request."
                    : "The reply was cut off before its tool call finished. Try a shorter request."))
                return
            }

            var results: [ToolResult] = []
            var invalidCalls: [ToolCall] = []
            for call in calls {
                try Task.checkCancellation()
                let errors = registry.validate(call)
                let result: ToolResult
                if !errors.isEmpty {
                    invalidCalls.append(call)
                    result = ToolRegistry.invalidResult(
                        call, errors: errors, schema: registry.tool(named: call.name)?.definition.inputSchema)
                    Log.assistant.notice("Invalid tool call \(call.name, privacy: .public): \(errors.joined(separator: "; "), privacy: .public)")
                } else if registry.tool(named: call.name)?.requiresConfirmation == true, await !confirm(call) {
                    result = ToolResult(callID: call.id, name: call.name, content: "The user declined this action.", isError: true)
                } else {
                    emit(.toolRunning(call))
                    result = await registry.execute(call)
                }
                emit(.toolFinished(call, result))
                results.append(result)
            }
            let resultMessage = ChatMessage(role: .tool, parts: results.map(ContentPart.toolResult))
            messages.append(resultMessage)
            emit(.toolResults(resultMessage))

            if invalidCalls.isEmpty {
                invalidRounds = 0
            } else {
                invalidRounds += 1
                if invalidRounds >= 2 {
                    let names = Set(invalidCalls.map(\.name)).sorted().joined(separator: ", ")
                    emit(.needsUser(
                        "The model couldn't make a valid call to \(names) after a retry. "
                            + "Could you rephrase, pick a stronger model, or use the buttons instead?"))
                    return
                }
            }
        }
        emit(.needsUser("Stopped after \(maxToolRounds) tool rounds. Say \"continue\" to keep going."))
    }
}

/// Tool calls a provider ran inside its own loop during one turn.
final class InlineCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(ToolCall, ToolResult)] = []

    func append(_ call: ToolCall, _ result: ToolResult) { lock.withLock { calls.append((call, result)) } }
    var all: [(ToolCall, ToolResult)] { lock.withLock { calls } }
}
