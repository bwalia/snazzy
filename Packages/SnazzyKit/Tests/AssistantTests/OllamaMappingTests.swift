import Foundation
import Testing
@testable import Assistant
@testable import SnazzyCore

@Suite struct OllamaMappingTests {
    /// Old file bodies and tool output are cut down to fit the context; recent ones stay whole.
    @Test func oldToolPayloadsAreShortened() throws {
        let big = String(repeating: "x", count: 10_000)
        func write(_ id: String) -> [ChatMessage] {
            [ChatMessage(role: .assistant, parts: [.toolCall(ToolCall(id: id, name: "write_file", arguments: ["path": "index.html", "content": .string(big)]))]),
             ChatMessage(role: .tool, parts: [.toolResult(ToolResult(callID: id, name: "write_file", content: big))])]
        }
        let history = [.user("build it")] + write("old") + Array(repeating: ChatMessage.user("more"), count: OllamaMapping.recentMessages - 2) + write("new")
        let messages = OllamaMapping.requestBody(ModelRequest(model: "m", messages: history))["messages"]?.arrayValue ?? []
        let oldContent = try #require(messages[1]["tool_calls"]?.arrayValue?.first?["function"]?["arguments"]?["content"]?.stringValue)
        #expect(oldContent.count < 2_000 && oldContent.contains("read_file"))
        #expect(messages[1]["tool_calls"]?.arrayValue?.first?["function"]?["arguments"]?["path"] == "index.html")
        #expect((messages[2]["content"]?.stringValue?.count ?? 0) < 2_000)
        let n = messages.count
        #expect(messages[n - 2]["tool_calls"]?.arrayValue?.first?["function"]?["arguments"]?["content"]?.stringValue == big)
        #expect(messages[n - 1]["content"]?.stringValue == big)
    }

    @Test func requestBody() throws {
        let tool = ToolDefinition(name: "list_devices", description: "List devices", inputSchema: ["type": "object", "properties": [:]])
        let call = ToolCall(id: "call_1", name: "list_devices", arguments: [:])
        let request = ModelRequest(
            model: "gpt-oss:120b", system: "sys",
            messages: [
                .user("what mics?"),
                ChatMessage(role: .assistant, parts: [
                    .opaque(provider: .anthropic, block: ["type": "thinking"]), .text("Checking."), .toolCall(call),
                ]),
                ChatMessage(role: .tool, parts: [.toolResult(ToolResult(callID: "call_1", name: "list_devices", content: "[]"))]),
            ],
            tools: [tool])
        let body = OllamaMapping.requestBody(request)
        #expect(body["model"] == "gpt-oss:120b")
        #expect(body["stream"] == true)
        #expect(body["options"]?["num_ctx"] == .number(Double(OllamaMapping.contextLength)))
        #expect(body["messages"] == [
            ["role": "system", "content": "sys"],
            ["role": "user", "content": "what mics?"],
            ["role": "assistant", "content": "Checking.", "tool_calls": [["function": ["name": "list_devices", "arguments": [:]]]]],
            ["role": "tool", "content": "[]", "tool_name": "list_devices"],
        ])
        #expect(body["tools"] == [[
            "type": "function",
            "function": ["name": "list_devices", "description": "List devices", "parameters": ["type": "object", "properties": [:]]],
        ]])
    }

    @Test func parsesTextStream() throws {
        var parser = OllamaStreamParser()
        var events: [StreamEvent] = []
        events += try parser.consume(line: #"{"model":"llama4","message":{"role":"assistant","content":"Hel"},"done":false}"#)
        events += try parser.consume(line: #"{"model":"llama4","message":{"role":"assistant","content":"lo","thinking":"hm"},"done":false}"#)
        events += try parser.consume(line: #"{"model":"llama4","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop","prompt_eval_count":12,"eval_count":3}"#)
        #expect(parser.isFinished)
        #expect(events == [.textDelta("Hel"), .thinkingDelta("hm"), .textDelta("lo")])
        guard case .completed(let message, let stop, let usage, let servedBy) = parser.completion() else {
            Issue.record("no completion"); return
        }
        #expect(message.parts == [.text("Hello")])
        #expect(stop == .endTurn)
        #expect(usage == TokenUsage(inputTokens: 12, outputTokens: 3))
        #expect(servedBy == "llama4")
    }

    @Test func parsesToolCallsIncludingStringArguments() throws {
        var parser = OllamaStreamParser()
        let events = try parser.consume(line: #"{"model":"gpt-oss:120b","message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"select_mic","arguments":{"name":"USB"}}},{"function":{"name":"open_preview","arguments":"{\"device\":\"iPad\"}"}}]},"done":false}"#)
        _ = try parser.consume(line: #"{"done":true,"done_reason":"stop"}"#)
        #expect(events == [.toolCallStarted(name: "select_mic"), .toolCallStarted(name: "open_preview")])
        guard case .completed(let message, let stop, _, _) = parser.completion() else { Issue.record("no completion"); return }
        #expect(stop == .toolUse)
        #expect(message.toolCalls.map(\.name) == ["select_mic", "open_preview"])
        #expect(message.toolCalls[0].arguments == ["name": "USB"])
        #expect(message.toolCalls[1].arguments == ["device": "iPad"])
        #expect(Set(message.toolCalls.map(\.id)).count == 2)
    }

    @Test func errorLineThrows() {
        var parser = OllamaStreamParser()
        #expect(throws: ProviderError.api(type: "ollama", message: "model 'nope' not found")) {
            try parser.consume(line: #"{"error":"model 'nope' not found"}"#)
        }
    }

    @Test func tagsListing() throws {
        let json = try JSONValue.parse(#"""
        {"models":[{"name":"gpt-oss:120b","details":{"parameter_size":"116.8B"},"capabilities":["completion","tools"]},
                   {"name":"tiny:latest","details":{},"capabilities":["completion"]}]}
        """#)
        let models = OllamaMapping.models(fromTags: json)
        #expect(models.map(\.id) == ["gpt-oss:120b", "tiny:latest"])
        #expect(models[0].displayName == "gpt-oss:120b (116.8B)")
        #expect(models[0].supportsTools == true)
        #expect(models[1].supportsTools == false)
    }
}
