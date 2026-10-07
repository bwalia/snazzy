import Foundation
import Testing
@testable import Assistant
@testable import SnazzyCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A provider that runs one tool itself (like the Apple on-device model), then answers.
struct SelfRunningProvider: ModelProvider {
    let kind = ProviderKind.appleOnDevice
    func listModels() async throws -> [ModelInfo] { [] }
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { c in
            Task {
                let result = await request.toolExecutor?(ToolCall(id: "a1", name: "set_inset", arguments: ["position": "topLeft"]))
                c.yield(.textDelta("Done: \(result?.content ?? "no executor")"))
                c.yield(.completed(message: ChatMessage(role: .assistant, parts: [.text("Done.")]), stopReason: .endTurn,
                                   usage: TokenUsage(), servedBy: "apple-on-device"))
                c.finish()
            }
        }
    }
}

@Suite struct AppleOnDeviceTests {
    @Test func condensedHistoryKeepsNewestWithinBudget() {
        let messages: [ChatMessage] = [
            .user("first question"),
            ChatMessage(role: .assistant, parts: [.text("first answer"), .toolCall(ToolCall(id: "1", name: "list_devices", arguments: [:]))]),
            ChatMessage(role: .tool, parts: [.toolResult(ToolResult(callID: "1", name: "list_devices", content: "{...}"))]),
            .user("second question"),
            ChatMessage(role: .assistant, parts: [.text("second answer")]),
        ]
        let all = AppleOnDeviceProvider.condensedHistory(messages, budget: 10_000)
        #expect(all == "User: first question\nAssistant used: list_devices\nAssistant: first answer\nUser: second question\nAssistant: second answer")
        let tight = AppleOnDeviceProvider.condensedHistory(messages, budget: 50)
        #expect(tight == "User: second question\nAssistant: second answer")
    }

    @Test func promptMentionsImagesItCannotSee() {
        let m = ChatMessage(role: .user, parts: [.image(mediaType: "image/png", data: Data([1])), .text("What's this?")])
        #expect(AppleOnDeviceProvider.prompt(from: [.user("old"), m]).contains("can't see images"))
        #expect(AppleOnDeviceProvider.prompt(from: [.user("hello")]) == "hello")
    }

    @Test func toolPriorityAndClipping() {
        let defs = ["write_file", "unknown_tool", "select_mic", "start_recording"].map {
            ToolDefinition(name: $0, description: "", inputSchema: ["type": "object"])
        }
        #expect(AppleToolPolicy.order(defs).map(\.name) == ["select_mic", "start_recording", "write_file"])
        #expect(AppleOnDeviceProvider.clip(String(repeating: "x", count: 3000)).count < 1500)
        let compact = AppleOnDeviceProvider.compactResult(#"{"microphones":[{"id":"AppleUSB:123","name":"USB Mic","selected":true}],"inset_device":null,"note":"x","tags":[]}"#)
        #expect(compact == #"{"microphones":[{"name":"USB Mic","selected":true}]}"#)
    }

    @Test func runnerRecordsToolsTheProviderRanItself() async throws {
        let registry = ToolRegistry([
            RegisteredTool(name: "set_inset", description: "Set inset", inputSchema: insetSchema) { _ in ["ok": true] },
        ])
        let runner = ConversationRunner(provider: SelfRunningProvider(), registry: registry, model: "apple-on-device")
        var events: [ConversationRunner.Event] = []
        for try await e in runner.run(history: [.user("inset top left")]) { events.append(e) }

        let finished = events.compactMap { if case .toolFinished(let c, let r) = $0 { (c, r) } else { nil } }
        #expect(finished.count == 1)
        #expect(finished.first?.1.content == #"{"ok":true}"#)
        // History gets: assistant tool call, tool result, then the final answer.
        let assistants = events.compactMap { if case .assistantMessage(let m, _, _) = $0 { m } else { nil } }
        #expect(assistants.count == 2)
        #expect(assistants[0].toolCalls.map(\.name) == ["set_inset"])
        #expect(assistants[1].text == "Done.")
        #expect(events.contains { if case .toolResults = $0 { true } else { false } })
        #expect(events.contains { if case .toolRunning = $0 { true } else { false } })
    }

    #if canImport(FoundationModels)
    @Test func schemaConversionBuildsAValidSchema() throws {
        guard #available(macOS 26.0, *) else { return }
        let root = AppleSchema.convert(insetSchema, name: "set_inset")
        _ = try GenerationSchema(root: root, dependencies: [])
    }
    #endif
}
