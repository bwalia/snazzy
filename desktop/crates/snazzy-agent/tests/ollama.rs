//! Ported from `OllamaMappingTests.swift`, plus HTTP tests against a local mock.

mod common;

use futures_util::StreamExt;
use serde_json::json;
use snazzy_agent::ollama::{self, OllamaStreamParser, RECENT_MESSAGES};
use snazzy_agent::{
    ChatMessage, ChatRole, ContentPart, ModelProvider, ModelRequest, OllamaProvider, ProviderError,
    ProviderKind, StopReason, StreamEvent, TokenUsage, ToolCall, ToolDefinition, ToolResult,
};

/// Old file bodies and tool output are cut down to fit the context; recent ones stay whole.
#[test]
fn old_tool_payloads_are_shortened() {
    let big = "x".repeat(10_000);
    let write = |id: &str| {
        vec![
            ChatMessage::new(
                ChatRole::Assistant,
                vec![ContentPart::ToolCall(ToolCall::new(
                    id,
                    "write_file",
                    json!({"path": "index.html", "content": big}),
                ))],
            ),
            ChatMessage::new(
                ChatRole::Tool,
                vec![ContentPart::ToolResult(ToolResult::new(
                    id,
                    "write_file",
                    big.clone(),
                ))],
            ),
        ]
    };
    let mut history = vec![ChatMessage::user("build it")];
    history.extend(write("old"));
    history.extend((0..RECENT_MESSAGES - 2).map(|_| ChatMessage::user("more")));
    history.extend(write("new"));
    let body = ollama::request_body(&ModelRequest::new("m", history));
    let messages = body["messages"].as_array().expect("messages");
    let old = messages[1]["tool_calls"][0]["function"]["arguments"]["content"]
        .as_str()
        .expect("old content");
    assert!(old.chars().count() < 2_000 && old.contains("read_file"));
    assert_eq!(
        messages[1]["tool_calls"][0]["function"]["arguments"]["path"],
        "index.html"
    );
    assert!(
        messages[2]["content"]
            .as_str()
            .expect("tool")
            .chars()
            .count()
            < 2_000
    );
    let n = messages.len();
    assert_eq!(
        messages[n - 2]["tool_calls"][0]["function"]["arguments"]["content"],
        big.as_str()
    );
    assert_eq!(messages[n - 1]["content"], big.as_str());
}

#[test]
fn request_body() {
    let tool = ToolDefinition {
        name: "list_devices".into(),
        description: "List devices".into(),
        input_schema: json!({"type": "object", "properties": {}}),
    };
    let call = ToolCall::new("call_1", "list_devices", json!({}));
    let mut request = ModelRequest::new(
        "gpt-oss:120b",
        vec![
            ChatMessage::user("what mics?"),
            ChatMessage::new(
                ChatRole::Assistant,
                vec![
                    ContentPart::Opaque {
                        provider: ProviderKind::Anthropic,
                        block: json!({"type": "thinking"}),
                    },
                    ContentPart::Text("Checking.".into()),
                    ContentPart::ToolCall(call),
                ],
            ),
            ChatMessage::new(
                ChatRole::Tool,
                vec![ContentPart::ToolResult(ToolResult::new(
                    "call_1",
                    "list_devices",
                    "[]",
                ))],
            ),
        ],
    );
    request.system = Some("sys".into());
    request.tools = vec![tool];
    let body = ollama::request_body(&request);
    assert_eq!(body["model"], "gpt-oss:120b");
    assert_eq!(body["stream"], true);
    assert_eq!(body["options"]["num_ctx"], ollama::CONTEXT_LENGTH);
    assert_eq!(
        body["messages"],
        json!([
            {"role": "system", "content": "sys"},
            {"role": "user", "content": "what mics?"},
            {"role": "assistant", "content": "Checking.", "tool_calls": [{"function": {"name": "list_devices", "arguments": {}}}]},
            {"role": "tool", "content": "[]", "tool_name": "list_devices"},
        ])
    );
    assert_eq!(
        body["tools"],
        json!([{
            "type": "function",
            "function": {"name": "list_devices", "description": "List devices", "parameters": {"type": "object", "properties": {}}},
        }])
    );
}

fn text_lines() -> [&'static str; 3] {
    [
        r#"{"model":"llama4","message":{"role":"assistant","content":"Hel"},"done":false}"#,
        r#"{"model":"llama4","message":{"role":"assistant","content":"lo","thinking":"hm"},"done":false}"#,
        r#"{"model":"llama4","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop","prompt_eval_count":12,"eval_count":3}"#,
    ]
}

#[test]
fn parses_text_stream() {
    let mut parser = OllamaStreamParser::new();
    let mut events = Vec::new();
    for line in text_lines() {
        events.extend(parser.consume(line).expect("line"));
    }
    assert!(parser.is_finished());
    assert_eq!(
        events,
        [
            StreamEvent::TextDelta("Hel".into()),
            StreamEvent::ThinkingDelta("hm".into()),
            StreamEvent::TextDelta("lo".into()),
        ]
    );
    let StreamEvent::Completed {
        message,
        stop_reason,
        usage,
        served_by,
    } = parser.completion()
    else {
        panic!("no completion")
    };
    assert_eq!(message.parts, [ContentPart::Text("Hello".into())]);
    assert_eq!(stop_reason, StopReason::EndTurn);
    assert_eq!(
        usage,
        TokenUsage {
            input_tokens: 12,
            output_tokens: 3
        }
    );
    assert_eq!(served_by.as_deref(), Some("llama4"));
}

#[test]
fn parses_tool_calls_including_string_arguments() {
    let mut parser = OllamaStreamParser::new();
    let events = parser
        .consume(r#"{"model":"gpt-oss:120b","message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"select_mic","arguments":{"name":"USB"}}},{"function":{"name":"open_preview","arguments":"{\"device\":\"iPad\"}"}}]},"done":false}"#)
        .expect("line");
    parser
        .consume(r#"{"done":true,"done_reason":"stop"}"#)
        .expect("done");
    assert_eq!(
        events,
        [
            StreamEvent::ToolCallStarted {
                name: "select_mic".into()
            },
            StreamEvent::ToolCallStarted {
                name: "open_preview".into()
            },
        ]
    );
    let StreamEvent::Completed {
        message,
        stop_reason,
        ..
    } = parser.completion()
    else {
        panic!("no completion")
    };
    assert_eq!(stop_reason, StopReason::ToolUse);
    let calls = message.tool_calls();
    assert_eq!(
        calls.iter().map(|c| c.name.as_str()).collect::<Vec<_>>(),
        ["select_mic", "open_preview"]
    );
    assert_eq!(calls[0].arguments, json!({"name": "USB"}));
    assert_eq!(calls[1].arguments, json!({"device": "iPad"}));
    assert_ne!(calls[0].id, calls[1].id);
    assert!(calls[0].id.starts_with("call_") && calls[0].id.len() == 13);
}

#[test]
fn tool_call_written_as_text_still_runs() {
    let mut parser = OllamaStreamParser::new();
    parser
        .consume(r#"{"message":{"content":"Next one.\n<tool_call><function=next_slide></function></tool_call>"},"done":true}"#)
        .expect("line");
    let StreamEvent::Completed {
        message,
        stop_reason,
        ..
    } = parser.completion()
    else {
        panic!("no completion")
    };
    assert_eq!(stop_reason, StopReason::ToolUse);
    assert_eq!(message.text(), "Next one.");
    assert_eq!(message.tool_calls()[0].name, "next_slide");

    let mut stray = OllamaStreamParser::new();
    stray
        .consume(r#"{"message":{"content":"Sure.<tool_call>"},"done":true,"done_reason":"length"}"#)
        .expect("line");
    let StreamEvent::Completed {
        message,
        stop_reason,
        ..
    } = stray.completion()
    else {
        panic!("no completion")
    };
    assert_eq!(message.text(), "Sure.");
    assert_eq!(stop_reason, StopReason::MaxTokens);
}

#[test]
fn error_line_throws() {
    let mut parser = OllamaStreamParser::new();
    assert_eq!(
        parser.consume(r#"{"error":"model 'nope' not found"}"#),
        Err(ProviderError::Api {
            error_type: "ollama".into(),
            message: "model 'nope' not found".into()
        })
    );
}

#[test]
fn tags_listing() {
    let json = json!({"models": [
        {"name": "gpt-oss:120b", "details": {"parameter_size": "116.8B"}, "capabilities": ["completion", "tools"]},
        {"name": "tiny:latest", "details": {}, "capabilities": ["completion"]},
        {"name": "old:latest"},
    ]});
    let models = ollama::models_from_tags(&json);
    assert_eq!(
        models.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(),
        ["gpt-oss:120b", "tiny:latest", "old:latest"]
    );
    assert_eq!(models[0].display_name, "gpt-oss:120b (116.8B)");
    assert_eq!(models[0].supports_tools, Some(true));
    assert_eq!(models[1].supports_tools, Some(false));
    assert_eq!(models[2].supports_tools, None);
}

// HTTP against a local mock server.

#[tokio::test]
async fn streams_ndjson_over_http() {
    let body: String = text_lines().iter().map(|l| format!("{l}\n")).collect();
    let (a, b) = body.split_at(40);
    let server = common::serve(vec![common::Reply::ok(
        "application/x-ndjson",
        vec![a.to_string(), b.to_string()],
    )])
    .await;
    let provider = OllamaProvider::new(&server.base_url).expect("provider");
    let request = ModelRequest::new("llama4", vec![ChatMessage::user("hi")]);
    let events: Vec<StreamEvent> = provider
        .stream(request.clone())
        .map(|e| e.expect("event"))
        .collect()
        .await;
    assert_eq!(events.len(), 4);
    let StreamEvent::Completed { message, .. } = &events[3] else {
        panic!("no completion")
    };
    assert_eq!(message.text(), "Hello");
    let recorded = server.requests.lock().expect("lock")[0].clone();
    assert_eq!(
        (recorded.method.as_str(), recorded.path.as_str()),
        ("POST", "/api/chat")
    );
    assert_eq!(recorded.json(), ollama::request_body(&request));
}

#[tokio::test]
async fn lists_tags_and_maps_http_errors() {
    let server = common::serve(vec![
        common::Reply::ok(
            "application/json",
            vec![r#"{"models":[{"name":"llama4:latest","capabilities":["tools"]}]}"#.into()],
        ),
        common::Reply {
            status: 404,
            content_type: "application/json",
            chunks: vec![r#"{"error":"model 'nope' not found"}"#.into()],
        },
    ])
    .await;
    let provider = OllamaProvider::new(&server.base_url).expect("provider");
    let models = provider.list_models().await.expect("models");
    assert_eq!(models[0].id, "llama4:latest");
    let events: Vec<_> = provider
        .stream(ModelRequest::new("nope", vec![ChatMessage::user("hi")]))
        .collect()
        .await;
    assert_eq!(
        events,
        [Err(ProviderError::Http {
            status: 404,
            message: "model 'nope' not found".into()
        })]
    );
    assert_eq!(server.requests.lock().expect("lock")[0].path, "/api/tags");
}
