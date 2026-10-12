//! Ported from `AnthropicMappingTests.swift`, plus HTTP tests against a local mock.

mod common;

use futures_util::StreamExt;
use serde_json::{Value, json};
use snazzy_agent::anthropic::{self, AnthropicStreamParser};
use snazzy_agent::{
    AnthropicProvider, ChatMessage, ChatRole, ContentPart, ModelProvider, ModelRequest,
    ProviderError, ProviderKind, StopReason, StreamEvent, TokenUsage, ToolCall, ToolDefinition,
    ToolResult,
};

fn tool() -> ToolDefinition {
    ToolDefinition {
        name: "set_inset".into(),
        description: "Position the camera inset".into(),
        input_schema: json!({"type": "object", "properties": {"position": {"type": "string"}}, "required": ["position"]}),
    }
}

#[test]
fn request_body_for_opus() {
    let mut request = ModelRequest::new("claude-opus-5-5", vec![ChatMessage::user("hi")]);
    request.system = Some("You are Snazzy.".into());
    request.tools = vec![tool()];
    request.max_tokens = 1000;
    request.effort = Some("medium".into());
    let body = anthropic::request_body(&request);
    assert_eq!(body["model"], "claude-opus-5-5");
    assert_eq!(body["max_tokens"], 1000);
    assert_eq!(body["stream"], true);
    assert_eq!(body["system"], "You are Snazzy.");
    assert_eq!(body["thinking"]["type"], "adaptive");
    assert_eq!(body["thinking"]["display"], "summarized");
    assert_eq!(body["output_config"]["effort"], "medium");
    assert_eq!(body["fallbacks"], "default");
    assert_eq!(
        anthropic::betas("claude-opus-5-5"),
        [
            "server-side-fallback-2026-07-01",
            "context-management-2025-06-27"
        ]
    );
    assert_eq!(body["cache_control"]["type"], "ephemeral");
    let clear = &body["context_management"]["edits"][0];
    assert_eq!(
        *clear,
        json!({
            "type": "clear_tool_uses_20250919",
            "trigger": {"type": "input_tokens", "value": 150_000},
            "keep": {"type": "tool_uses", "value": 6},
            "clear_at_least": {"type": "input_tokens", "value": 40_000},
            "clear_tool_inputs": true,
        })
    );
    let tools = body["tools"].as_array().expect("tools");
    assert_eq!(tools[0]["name"], "set_inset");
    assert_eq!(tools[0]["input_schema"], tool().input_schema);
    assert_eq!(tools[0]["eager_input_streaming"], true);
    assert_eq!(
        body["messages"],
        json!([{"role": "user", "content": [{"type": "text", "text": "hi"}]}])
    );
}

#[test]
fn no_fallbacks_for_other_models() {
    let body = anthropic::request_body(&ModelRequest::new(
        "claude-haiku-5-5",
        vec![ChatMessage::user("x")],
    ));
    assert!(body.get("fallbacks").is_none());
    assert!(body.get("tools").is_none());
    assert!(body.get("system").is_none());
    assert!(body.get("output_config").is_none());
    assert_eq!(
        anthropic::betas("claude-haiku-5-5"),
        ["context-management-2025-06-27"]
    );
}

#[test]
fn history_with_tools_maps_and_merges_roles() {
    let thinking = json!({"type": "thinking", "thinking": "hmm", "signature": "sig"});
    let call = ToolCall::new("toolu_1", "set_inset", json!({"position": "bottomRight"}));
    let history = vec![
        ChatMessage::user("put me bottom right"),
        ChatMessage::new(
            ChatRole::Assistant,
            vec![
                ContentPart::Opaque {
                    provider: ProviderKind::Anthropic,
                    block: thinking.clone(),
                },
                ContentPart::Opaque {
                    provider: ProviderKind::Ollama,
                    block: json!({"ignored": true}),
                },
                ContentPart::Text("Sure.".into()),
                ContentPart::ToolCall(call),
            ],
        ),
        ChatMessage::new(
            ChatRole::Tool,
            vec![ContentPart::ToolResult(ToolResult::new(
                "toolu_1",
                "set_inset",
                "{\"ok\":true}",
            ))],
        ),
        ChatMessage::user("thanks"),
    ];
    let messages = anthropic::messages(&history);
    assert_eq!(messages.len(), 3);
    assert_eq!(
        messages[1],
        json!({
            "role": "assistant",
            "content": [
                thinking,
                {"type": "text", "text": "Sure."},
                {"type": "tool_use", "id": "toolu_1", "name": "set_inset", "input": {"position": "bottomRight"}},
            ],
        })
    );
    // Tool results and the next user text are merged into one user turn.
    assert_eq!(
        messages[2],
        json!({
            "role": "user",
            "content": [
                {"type": "tool_result", "tool_use_id": "toolu_1", "content": "{\"ok\":true}", "is_error": false},
                {"type": "text", "text": "thanks"},
            ],
        })
    );
}

/// Thinking blocks go back exactly as stored, however many turns later.
#[test]
fn history_is_sent_unchanged() {
    let redacted = json!({"type": "redacted_thinking", "data": "EmwKAhgBEgy3va3pzix/LafPsn4a"});
    let thinking =
        json!({"type": "thinking", "thinking": "long ".repeat(500), "signature": "Wa/b+c=="});
    let mut history = vec![ChatMessage::user("start")];
    for i in 0..30 {
        history.push(ChatMessage::new(
            ChatRole::Assistant,
            vec![
                ContentPart::Opaque {
                    provider: ProviderKind::Anthropic,
                    block: thinking.clone(),
                },
                ContentPart::Opaque {
                    provider: ProviderKind::Anthropic,
                    block: redacted.clone(),
                },
                ContentPart::ToolCall(ToolCall::new(
                    format!("t{i}"),
                    "write_file",
                    json!({"content": "x".repeat(5000)}),
                )),
            ],
        ));
        history.push(ChatMessage::new(
            ChatRole::Tool,
            vec![ContentPart::ToolResult(ToolResult::new(
                format!("t{i}"),
                "write_file",
                "y".repeat(5000),
            ))],
        ));
    }
    let messages = anthropic::messages(&history);
    assert_eq!(messages.len(), 61);
    for (i, m) in messages.iter().enumerate().skip(1).step_by(2) {
        assert_eq!(m["content"][0], thinking, "turn {i}");
        assert_eq!(m["content"][1], redacted, "turn {i}");
        assert_eq!(
            m["content"][2]["input"]["content"].as_str().map(str::len),
            Some(5000)
        );
    }
    assert_eq!(
        messages[2]["content"][0]["content"].as_str().map(str::len),
        Some(5000)
    );
}

fn stream_lines() -> Vec<&'static str> {
    vec![
        "event: message_start",
        r#"data: {"type":"message_start","message":{"id":"msg_1","model":"claude-opus-5-5","usage":{"input_tokens":120,"cache_read_input_tokens":30,"output_tokens":1}}}"#,
        r#"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
        r#"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Plan it."}}"#,
        r#"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}"#,
        r#"data: {"type":"content_block_stop","index":0}"#,
        r#"data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
        r#"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Moving "}}"#,
        r#"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"it."}}"#,
        r#"data: {"type":"content_block_stop","index":1}"#,
        r#"data: {"type":"ping"}"#,
        r#"data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_9","name":"set_inset","input":{}}}"#,
        r#"data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"posi"}}"#,
        r#"data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"tion\": \"bottomRight\"}"}}"#,
        r#"data: {"type":"content_block_stop","index":2}"#,
        r#"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":42}}"#,
        r#"data: {"type":"message_stop"}"#,
    ]
}

fn expected_deltas() -> Vec<StreamEvent> {
    vec![
        StreamEvent::ThinkingDelta("Plan it.".into()),
        StreamEvent::TextDelta("Moving ".into()),
        StreamEvent::TextDelta("it.".into()),
        StreamEvent::ToolCallStarted {
            name: "set_inset".into(),
        },
        StreamEvent::ToolInputDelta {
            call_id: "toolu_9".into(),
            name: "set_inset".into(),
            fragment: "{\"posi".into(),
        },
        StreamEvent::ToolInputDelta {
            call_id: "toolu_9".into(),
            name: "set_inset".into(),
            fragment: "tion\": \"bottomRight\"}".into(),
        },
    ]
}

fn expected_parts() -> Vec<ContentPart> {
    vec![
        ContentPart::Opaque {
            provider: ProviderKind::Anthropic,
            block: json!({"type": "thinking", "thinking": "Plan it.", "signature": "abc"}),
        },
        ContentPart::Text("Moving it.".into()),
        ContentPart::ToolCall(ToolCall::new(
            "toolu_9",
            "set_inset",
            json!({"position": "bottomRight"}),
        )),
    ]
}

#[test]
fn parses_stream_with_thinking_text_and_tool_use() {
    let mut parser = AnthropicStreamParser::new();
    let mut events = Vec::new();
    for line in stream_lines() {
        events.extend(parser.consume_sse_line(line).expect("line"));
    }
    assert!(parser.is_finished());
    assert_eq!(events, expected_deltas());
    let StreamEvent::Completed {
        message,
        stop_reason,
        usage,
        served_by,
    } = parser.completion()
    else {
        panic!("no completion")
    };
    assert_eq!(stop_reason, StopReason::ToolUse);
    assert_eq!(
        usage,
        TokenUsage {
            input_tokens: 150,
            output_tokens: 42
        }
    );
    assert_eq!(served_by.as_deref(), Some("claude-opus-5-5"));
    assert_eq!(message.role, ChatRole::Assistant);
    assert_eq!(message.parts, expected_parts());
}

#[test]
fn truncated_tool_input_is_kept_as_string() {
    let mut parser = AnthropicStreamParser::new();
    parser
        .consume_event(&json!({"type": "content_block_start", "index": 0,
            "content_block": {"type": "tool_use", "id": "t", "name": "x", "input": {}}}))
        .expect("start");
    parser
        .consume_event(&json!({"type": "content_block_delta", "index": 0,
            "delta": {"type": "input_json_delta", "partial_json": "{\"a\": "}}))
        .expect("delta");
    parser
        .consume_event(&json!({"type": "message_delta", "delta": {"stop_reason": "max_tokens"}}))
        .expect("message_delta");
    let StreamEvent::Completed {
        message,
        stop_reason,
        ..
    } = parser.completion()
    else {
        panic!("no completion")
    };
    assert_eq!(stop_reason, StopReason::MaxTokens);
    assert_eq!(
        message.tool_calls()[0].arguments,
        Value::String("{\"a\":".into())
    );
}

#[test]
fn redacted_thinking_is_kept_opaque() {
    let mut parser = AnthropicStreamParser::new();
    parser
        .consume_event(&json!({"type": "content_block_start", "index": 0,
            "content_block": {"type": "redacted_thinking", "data": "xyz"}}))
        .expect("start");
    let StreamEvent::Completed { message, .. } = parser.completion() else {
        panic!("no completion")
    };
    assert_eq!(
        message.parts,
        [ContentPart::Opaque {
            provider: ProviderKind::Anthropic,
            block: json!({"type": "redacted_thinking", "data": "xyz"})
        }]
    );
}

#[test]
fn stream_error_throws() {
    let mut parser = AnthropicStreamParser::new();
    let error = parser
        .consume_sse_line(
            r#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
        )
        .expect_err("error event");
    assert_eq!(
        error,
        ProviderError::Api {
            error_type: "overloaded_error".into(),
            message: "Overloaded".into()
        }
    );
    assert_eq!(error.to_string(), "overloaded_error: Overloaded");
    assert!(matches!(
        parser.consume_sse_line("data: {nope"),
        Err(ProviderError::MalformedResponse(_))
    ));
}

#[test]
fn images_become_base64_blocks() {
    let png = vec![0x89, 0x50, 0x4E, 0x47];
    let message = ChatMessage::new(
        ChatRole::User,
        vec![
            ContentPart::Image {
                media_type: "image/png".into(),
                data: png.clone(),
            },
            ContentPart::Text("What is this?".into()),
        ],
    );
    let messages = anthropic::messages(std::slice::from_ref(&message));
    assert_eq!(
        messages[0]["content"][0],
        json!({"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "iVBORw=="}})
    );
    let ollama = snazzy_agent::ollama::request_body(&ModelRequest::new("m", vec![message]));
    assert_eq!(ollama["messages"][0]["images"], json!(["iVBORw=="]));
}

#[test]
fn error_body_message() {
    let json = json!({"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}});
    assert_eq!(
        anthropic::error_message(&json).as_deref(),
        Some("authentication_error: invalid x-api-key")
    );
}

#[test]
fn missing_key_and_bad_url() {
    assert_eq!(
        AnthropicProvider::new("").expect_err("empty key"),
        ProviderError::MissingApiKey(ProviderKind::Anthropic)
    );
    assert_eq!(
        AnthropicProvider::with_base_url("k", "nope").expect_err("bad url"),
        ProviderError::InvalidBaseUrl("nope".into())
    );
    assert_eq!(
        ProviderError::MissingApiKey(ProviderKind::Anthropic).to_string(),
        "No API key for Anthropic. Add one in Settings."
    );
}

#[test]
fn debug_never_shows_the_key() {
    let provider = AnthropicProvider::new("sk-test-not-a-real-key").expect("provider");
    assert!(!format!("{provider:?}").contains("sk-test"));
}

// HTTP against a local mock server.

#[tokio::test]
async fn streams_over_http_with_headers() {
    let body: String = stream_lines()
        .iter()
        .map(|l| format!("{l}\r\n\r\n"))
        .collect();
    // Split mid-line so the line buffer is exercised.
    let (a, b) = body.split_at(body.len() / 3);
    let server = common::serve(vec![common::Reply::ok(
        "text/event-stream",
        vec![a.to_string(), b.to_string()],
    )])
    .await;
    let provider = AnthropicProvider::with_base_url("test-key", &format!("{}/", server.base_url))
        .expect("provider");
    let mut request = ModelRequest::new("claude-opus-5-5", vec![ChatMessage::user("hi")]);
    request.tools = vec![tool()];
    let events: Vec<StreamEvent> = provider
        .stream(request.clone())
        .map(|e| e.expect("event"))
        .collect()
        .await;
    let (last, deltas) = events.split_last().expect("events");
    assert_eq!(deltas, expected_deltas().as_slice());
    let StreamEvent::Completed { message, .. } = last else {
        panic!("last event is not Completed")
    };
    assert_eq!(message.parts, expected_parts());

    let recorded = server.requests.lock().expect("lock")[0].clone();
    assert_eq!(recorded.method, "POST");
    assert_eq!(recorded.path, "/v1/messages");
    assert_eq!(recorded.header("x-api-key"), Some("test-key"));
    assert_eq!(recorded.header("anthropic-version"), Some("2023-06-01"));
    assert_eq!(recorded.header("content-type"), Some("application/json"));
    assert_eq!(
        recorded.header("anthropic-beta"),
        Some("server-side-fallback-2026-07-01,context-management-2025-06-27")
    );
    assert_eq!(recorded.json(), anthropic::request_body(&request));
}

#[tokio::test]
async fn http_error_uses_the_api_message() {
    let server = common::serve(vec![common::Reply {
        status: 401,
        content_type: "application/json",
        chunks: vec![
            r#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.into(),
        ],
    }])
    .await;
    let provider = AnthropicProvider::with_base_url("bad", &server.base_url).expect("provider");
    let events: Vec<_> = provider
        .stream(ModelRequest::new(
            "claude-opus-5-5",
            vec![ChatMessage::user("hi")],
        ))
        .collect()
        .await;
    assert_eq!(
        events,
        [Err(ProviderError::Http {
            status: 401,
            message: "authentication_error: invalid x-api-key".into()
        })]
    );
}

#[tokio::test]
async fn lists_models() {
    let server = common::serve(vec![common::Reply::ok(
        "application/json",
        vec![r#"{"data":[{"id":"claude-opus-5-5","display_name":"Claude Opus 5.5"},{"id":"claude-sonnet-5-5"}]}"#.into()],
    )])
    .await;
    let provider = AnthropicProvider::with_base_url("k", &server.base_url).expect("provider");
    let models = provider.list_models().await.expect("models");
    assert_eq!(models[0].id, "claude-opus-5-5");
    assert_eq!(models[0].display_name, "Claude Opus 5.5");
    assert_eq!(models[1].display_name, "claude-sonnet-5-5");
    assert_eq!(models[1].supports_tools, Some(true));
    let recorded = server.requests.lock().expect("lock")[0].clone();
    assert_eq!(
        (recorded.method.as_str(), recorded.path.as_str()),
        ("GET", "/v1/models")
    );
}

#[tokio::test]
async fn unreachable_host() {
    let url = common::closed_port_url().await;
    let provider = AnthropicProvider::with_base_url("k", &url).expect("provider");
    let events: Vec<_> = provider
        .stream(ModelRequest::new(
            "claude-opus-5-5",
            vec![ChatMessage::user("hi")],
        ))
        .collect()
        .await;
    assert_eq!(
        events,
        [Err(ProviderError::Unreachable(
            "Cannot connect to 127.0.0.1. Is it running?".into()
        ))]
    );
}
