import Foundation
import Testing
@testable import Assistant
@testable import SnazzyCore

/// Replays scripted assistant turns and records the requests it receives.
final class ScriptedProvider: ModelProvider, @unchecked Sendable {
    let kind = ProviderKind.ollama
    private var turns: [(ChatMessage, StopReason)]
    private(set) var requests: [ModelRequest] = []
    private let lock = NSLock()

    init(_ turns: [(ChatMessage, StopReason)]) { self.turns = turns }

    func listModels() async throws -> [ModelInfo] { [] }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        let turn: (ChatMessage, StopReason)? = lock.withLock {
            requests.append(request)
            return turns.isEmpty ? nil : turns.removeFirst()
        }
        return AsyncThrowingStream { c in
            guard let (message, stop) = turn else {
                c.finish(throwing: ProviderError.malformedResponse("script exhausted")); return
            }
            if !message.text.isEmpty { c.yield(.textDelta(message.text)) }
            c.yield(.completed(message: message, stopReason: stop, usage: TokenUsage(inputTokens: 10, outputTokens: 5), servedBy: "mock"))
            c.finish()
        }
    }
}

func call(_ name: String, _ args: JSONValue, id: String = UUID().uuidString) -> ChatMessage {
    ChatMessage(role: .assistant, parts: [.toolCall(ToolCall(id: id, name: name, arguments: args))])
}

func reply(_ text: String) -> ChatMessage { ChatMessage(role: .assistant, parts: [.text(text)]) }

@Suite struct ConversationRunnerTests {
    let registry = ToolRegistry([
        RegisteredTool(name: "set_inset", description: "Set inset", inputSchema: insetSchema) { _ in ["ok": true] },
        RegisteredTool(name: "delete_take", description: "Delete", inputSchema: ["type": "object"], requiresConfirmation: true) { _ in
            ["deleted": true]
        },
    ])

    func run(_ provider: ScriptedProvider, confirm: @escaping @Sendable (ToolCall) async -> Bool = { _ in false })
        async throws -> [ConversationRunner.Event]
    {
        let runner = ConversationRunner(provider: provider, registry: registry, model: "m", confirm: confirm)
        var events: [ConversationRunner.Event] = []
        for try await e in runner.run(history: [.user("go")]) { events.append(e) }
        return events
    }

    @Test func runsToolThenAnswers() async throws {
        let provider = ScriptedProvider([
            (call("set_inset", ["position": "bottomRight"], id: "c1"), .toolUse),
            (reply("Done."), .endTurn),
        ])
        let events = try await run(provider)
        #expect(provider.requests.count == 2)
        let second = provider.requests[1].messages
        #expect(second.count == 3)
        #expect(second[2].role == .tool)
        #expect(second[2].parts == [.toolResult(ToolResult(callID: "c1", name: "set_inset", content: #"{"ok":true}"#))])
        #expect(provider.requests[0].tools.map(\.name) == ["set_inset", "delete_take"])
        #expect(!events.contains { if case .needsUser = $0 { true } else { false } })
    }

    @Test func retriesOnceAfterInvalidCall() async throws {
        let provider = ScriptedProvider([
            (call("set_inset", ["position": "middle"]), .toolUse),
            (call("set_inset", ["position": "topLeft"]), .toolUse),
            (reply("Fixed."), .endTurn),
        ])
        let events = try await run(provider)
        #expect(provider.requests.count == 3)
        guard case .toolResult(let first) = provider.requests[1].messages.last?.parts.first else {
            Issue.record("missing tool result"); return
        }
        #expect(first.isError)
        #expect(first.content.contains("must be one of"))
        #expect(!events.contains { if case .needsUser = $0 { true } else { false } })
    }

    @Test func asksUserAfterSecondInvalidCall() async throws {
        let provider = ScriptedProvider([
            (call("set_inset", ["position": 1]), .toolUse),
            (call("set_inset", [:]), .toolUse),
            (reply("never reached"), .endTurn),
        ])
        let events = try await run(provider)
        #expect(provider.requests.count == 2)
        let asks = events.compactMap { if case .needsUser(let m) = $0 { m } else { nil } }
        #expect(asks.count == 1)
        #expect(asks[0].contains("set_inset"))
    }

    @Test func destructiveToolNeedsConfirmation() async throws {
        let declined = ScriptedProvider([(call("delete_take", [:]), .toolUse), (reply("ok"), .endTurn)])
        _ = try await run(declined)
        guard case .toolResult(let r1) = declined.requests[1].messages.last?.parts.first else { Issue.record("no result"); return }
        #expect(r1.content == "The user declined this action.")

        let approved = ScriptedProvider([(call("delete_take", [:]), .toolUse), (reply("ok"), .endTurn)])
        _ = try await run(approved, confirm: { _ in true })
        guard case .toolResult(let r2) = approved.requests[1].messages.last?.parts.first else { Issue.record("no result"); return }
        #expect(r2.content == #"{"deleted":true}"#)
    }

    @Test func truncatedToolCallIsNotExecuted() async throws {
        let provider = ScriptedProvider([(call("set_inset", ["position": "topLeft"]), .maxTokens)])
        let events = try await run(provider)
        #expect(provider.requests.count == 1)
        let results = events.compactMap { if case .toolResults(let m) = $0 { m } else { nil } }
        guard case .toolResult(let r)? = results.first?.parts.first else { Issue.record("no result"); return }
        #expect(r.isError)
        #expect(events.contains { if case .needsUser = $0 { true } else { false } })
    }
}
