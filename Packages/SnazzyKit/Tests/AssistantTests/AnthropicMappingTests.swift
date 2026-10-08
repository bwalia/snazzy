import Foundation
import Testing
@testable import Assistant
@testable import SnazzyCore

@Suite struct AnthropicMappingTests {
    let tool = ToolDefinition(
        name: "set_inset", description: "Position the camera inset",
        inputSchema: ["type": "object", "properties": ["position": ["type": "string"]], "required": ["position"]])

    @Test func requestBodyForOpus() throws {
        let request = ModelRequest(
            model: "claude-opus-5-5", system: "You are Snazzy.", messages: [.user("hi")], tools: [tool],
            maxTokens: 1000, effort: "medium")
        let body = AnthropicMapping.requestBody(request)
        #expect(body["model"] == "claude-opus-5-5")
        #expect(body["max_tokens"] == 1000)
        #expect(body["stream"] == true)
        #expect(body["system"] == "You are Snazzy.")
        #expect(body["thinking"]?["type"] == "adaptive")
        #expect(body["output_config"]?["effort"] == "medium")
        #expect(body["fallbacks"] == "default")
        #expect(AnthropicMapping.betas(for: "claude-opus-5-5") == ["server-side-fallback-2026-07-01"])
        let tools = try #require(body["tools"]?.arrayValue)
        #expect(tools[0]["name"] == "set_inset")
        #expect(tools[0]["input_schema"] == tool.inputSchema)
        #expect(tools[0]["eager_input_streaming"] == true)
        #expect(body["messages"] == [["role": "user", "content": [["type": "text", "text": "hi"]]]])
    }

    @Test func noFallbacksForOtherModels() {
        let body = AnthropicMapping.requestBody(ModelRequest(model: "claude-haiku-5-5", messages: [.user("x")]))
        #expect(body["fallbacks"] == nil)
        #expect(body["tools"] == nil)
        #expect(AnthropicMapping.betas(for: "claude-haiku-5-5").isEmpty)
    }

    @Test func historyWithToolsMapsAndMergesRoles() throws {
        let thinking: JSONValue = ["type": "thinking", "thinking": "hmm", "signature": "sig"]
        let call = ToolCall(id: "toolu_1", name: "set_inset", arguments: ["position": "bottomRight"])
        let history: [ChatMessage] = [
            .user("put me bottom right"),
            ChatMessage(role: .assistant, parts: [
                .opaque(provider: .anthropic, block: thinking),
                .opaque(provider: .ollama, block: ["ignored": true]),
                .text("Sure."),
                .toolCall(call),
            ]),
            ChatMessage(role: .tool, parts: [.toolResult(ToolResult(callID: "toolu_1", name: "set_inset", content: "{\"ok\":true}"))]),
            .user("thanks"),
        ]
        let messages = AnthropicMapping.messages(history)
        #expect(messages.count == 3)
        #expect(messages[1] == [
            "role": "assistant",
            "content": [
                thinking,
                ["type": "text", "text": "Sure."],
                ["type": "tool_use", "id": "toolu_1", "name": "set_inset", "input": ["position": "bottomRight"]],
            ],
        ])
        // Tool results and the next user text are merged into one user turn.
        #expect(messages[2] == [
            "role": "user",
            "content": [
                ["type": "tool_result", "tool_use_id": "toolu_1", "content": "{\"ok\":true}", "is_error": false],
                ["type": "text", "text": "thanks"],
            ],
        ])
    }

    @Test func parsesStreamWithThinkingTextAndToolUse() throws {
        let lines = [
            "event: message_start",
            #"data: {"type":"message_start","message":{"id":"msg_1","model":"claude-opus-5-5","usage":{"input_tokens":120,"cache_read_input_tokens":30,"output_tokens":1}}}"#,
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Plan it."}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Moving "}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"it."}}"#,
            #"data: {"type":"content_block_stop","index":1}"#,
            #"data: {"type":"ping"}"#,
            #"data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_9","name":"set_inset","input":{}}}"#,
            #"data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"posi"}}"#,
            #"data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"tion\": \"bottomRight\"}"}}"#,
            #"data: {"type":"content_block_stop","index":2}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":42}}"#,
            #"data: {"type":"message_stop"}"#,
        ]
        var parser = AnthropicStreamParser()
        var events: [StreamEvent] = []
        for line in lines { events += try parser.consume(sseLine: line) }
        #expect(parser.isFinished)
        #expect(events == [
            .thinkingDelta("Plan it."), .textDelta("Moving "), .textDelta("it."), .toolCallStarted(name: "set_inset"),
            .toolInputDelta(callID: "toolu_9", name: "set_inset", fragment: "{\"posi"),
            .toolInputDelta(callID: "toolu_9", name: "set_inset", fragment: "tion\": \"bottomRight\"}"),
        ])
        guard case .completed(let message, let stop, let usage, let servedBy) = parser.completion() else {
            Issue.record("no completion"); return
        }
        #expect(stop == .toolUse)
        #expect(usage == TokenUsage(inputTokens: 150, outputTokens: 42))
        #expect(servedBy == "claude-opus-5-5")
        #expect(message.parts == [
            .opaque(provider: .anthropic, block: ["type": "thinking", "thinking": "Plan it.", "signature": "abc"]),
            .text("Moving it."),
            .toolCall(ToolCall(id: "toolu_9", name: "set_inset", arguments: ["position": "bottomRight"])),
        ])
    }

    @Test func truncatedToolInputIsKeptAsString() throws {
        var parser = AnthropicStreamParser()
        _ = try parser.consume(event: ["type": "content_block_start", "index": 0,
            "content_block": ["type": "tool_use", "id": "t", "name": "x", "input": [:]]])
        _ = try parser.consume(event: ["type": "content_block_delta", "index": 0,
            "delta": ["type": "input_json_delta", "partial_json": "{\"a\": "]])
        _ = try parser.consume(event: ["type": "message_delta", "delta": ["stop_reason": "max_tokens"]])
        guard case .completed(let message, let stop, _, _) = parser.completion() else { Issue.record("no completion"); return }
        #expect(stop == .maxTokens)
        #expect(message.toolCalls.first?.arguments == .string("{\"a\":"))
    }

    @Test func redactedThinkingIsKeptOpaque() throws {
        var parser = AnthropicStreamParser()
        _ = try parser.consume(event: ["type": "content_block_start", "index": 0,
            "content_block": ["type": "redacted_thinking", "data": "xyz"]])
        guard case .completed(let message, _, _, _) = parser.completion() else { Issue.record("no completion"); return }
        #expect(message.parts == [.opaque(provider: .anthropic, block: ["type": "redacted_thinking", "data": "xyz"])])
    }

    @Test func streamErrorThrows() {
        var parser = AnthropicStreamParser()
        #expect(throws: ProviderError.api(type: "overloaded_error", message: "Overloaded")) {
            try parser.consume(sseLine: #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        }
    }

    @Test func imagesBecomeBase64Blocks() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let messages = AnthropicMapping.messages([
            ChatMessage(role: .user, parts: [.image(mediaType: "image/png", data: png), .text("What is this?")]),
        ])
        #expect(messages[0]["content"]?.arrayValue?.first == [
            "type": "image", "source": ["type": "base64", "media_type": "image/png", "data": .string(png.base64EncodedString())],
        ])
        let ollama = OllamaMapping.requestBody(ModelRequest(model: "m", messages: [
            ChatMessage(role: .user, parts: [.image(mediaType: "image/png", data: png), .text("hi")]),
        ]))
        #expect(ollama["messages"]?.arrayValue?.first?["images"] == [.string(png.base64EncodedString())])
    }

    @Test func errorBodyMessage() {
        let json: JSONValue = ["type": "error", "error": ["type": "authentication_error", "message": "invalid x-api-key"]]
        #expect(AnthropicMapping.errorMessage(json) == "authentication_error: invalid x-api-key")
    }
}

@Suite struct TextToolCallTests {
    @Test func qwenXMLStyle() throws {
        let text = """
        I'll create the deck. Let me check the devices first.
        <function=list_devices>
        </function>
        </tool_call>
        """
        let r = try #require(TextToolCalls.extract(from: text))
        #expect(r.calls.count == 1 && r.calls[0].name == "list_devices")
        #expect(r.text == "I'll create the deck. Let me check the devices first.")

        let two = """
        <tool_call>
        <function=write_file>
        <parameter=path>
        index.html
        </parameter>
        <parameter=content>
        <h1>Hi</h1>
        </parameter>
        </function>
        </tool_call>
        <tool_call><function=show_slide><parameter=index>2</parameter></function></tool_call>
        """
        let r2 = try #require(TextToolCalls.extract(from: two))
        #expect(r2.calls.map(\.name) == ["write_file", "show_slide"])
        #expect(r2.calls[0].arguments["path"]?.stringValue == "index.html")
        #expect(r2.calls[0].arguments["content"]?.stringValue == "<h1>Hi</h1>")
        #expect(r2.calls[1].arguments["index"] == .number(2))
        #expect(r2.text.isEmpty)
    }

    @Test func jsonStyleAndPlainText() throws {
        let r = try #require(TextToolCalls.extract(from: #"<tool_call>{"name": "next_slide", "arguments": {}}</tool_call>"#))
        #expect(r.calls.first?.name == "next_slide")
        #expect(TextToolCalls.extract(from: "Just a normal answer about <b>HTML</b>.") == nil)
    }
}
