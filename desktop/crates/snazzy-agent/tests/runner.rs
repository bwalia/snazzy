//! Ported from `ConversationRunnerTests.swift`, plus round-limit, refusal and
//! cancellation tests.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures_util::future::BoxFuture;
use futures_util::stream::{self, StreamExt};
use serde_json::{Value, json};
use snazzy_agent::{
    ChatMessage, ChatRole, ContentPart, ConversationRunner, EventStream, ModelInfo, ModelProvider,
    ModelRequest, ProviderError, ProviderKind, RegisteredTool, RunnerEvent, StopReason,
    StreamEvent, TokenUsage, ToolCall, ToolRegistry, ToolResult,
};

/// Replays scripted assistant turns and records the requests it receives.
struct ScriptedProvider {
    turns: Mutex<Vec<(ChatMessage, StopReason)>>,
    requests: Mutex<Vec<ModelRequest>>,
}

impl ScriptedProvider {
    fn new(turns: Vec<(ChatMessage, StopReason)>) -> Arc<Self> {
        Arc::new(Self {
            turns: Mutex::new(turns),
            requests: Mutex::new(Vec::new()),
        })
    }

    fn requests(&self) -> Vec<ModelRequest> {
        self.requests.lock().expect("lock").clone()
    }
}

impl ModelProvider for ScriptedProvider {
    fn kind(&self) -> ProviderKind {
        ProviderKind::Ollama
    }

    fn list_models(&self) -> BoxFuture<'_, Result<Vec<ModelInfo>, ProviderError>> {
        Box::pin(async { Ok(Vec::new()) })
    }

    fn stream(&self, request: ModelRequest) -> EventStream {
        self.requests.lock().expect("lock").push(request);
        let mut turns = self.turns.lock().expect("lock");
        if turns.is_empty() {
            return stream::iter([Err(ProviderError::MalformedResponse(
                "script exhausted".into(),
            ))])
            .boxed();
        }
        let (message, stop_reason) = turns.remove(0);
        let mut events = Vec::new();
        if !message.text().is_empty() {
            events.push(Ok(StreamEvent::TextDelta(message.text())));
        }
        events.push(Ok(StreamEvent::Completed {
            message,
            stop_reason,
            usage: TokenUsage {
                input_tokens: 10,
                output_tokens: 5,
            },
            served_by: Some("mock".into()),
        }));
        stream::iter(events).boxed()
    }
}

fn call(name: &str, args: Value, id: &str) -> ChatMessage {
    ChatMessage::new(
        ChatRole::Assistant,
        vec![ContentPart::ToolCall(ToolCall::new(id, name, args))],
    )
}

fn reply(text: &str) -> ChatMessage {
    ChatMessage::new(ChatRole::Assistant, vec![ContentPart::Text(text.into())])
}

fn inset_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "position": {"type": "string", "enum": ["topLeft", "topRight", "bottomLeft", "bottomRight"]},
            "size": {"type": "number", "minimum": 0.05, "maximum": 0.6},
        },
        "required": ["position"],
        "additionalProperties": false,
    })
}

fn registry() -> ToolRegistry {
    ToolRegistry::new([
        RegisteredTool::new("set_inset", "Set inset", inset_schema(), |_| async {
            Ok(json!({"ok": true}))
        }),
        RegisteredTool::new(
            "delete_take",
            "Delete",
            json!({"type": "object"}),
            |_| async { Ok(json!({"deleted": true})) },
        )
        .requiring_confirmation(),
    ])
}

async fn run(
    provider: Arc<ScriptedProvider>,
    runner: Option<ConversationRunner>,
) -> Vec<RunnerEvent> {
    let runner = runner.unwrap_or_else(|| ConversationRunner::new(provider, registry(), "m"));
    runner
        .run(vec![ChatMessage::user("go")])
        .map(|e| e.expect("event"))
        .collect()
        .await
}

fn needs_user(events: &[RunnerEvent]) -> Vec<String> {
    events
        .iter()
        .filter_map(|e| match e {
            RunnerEvent::NeedsUser(m) => Some(m.clone()),
            _ => None,
        })
        .collect()
}

fn last_result(request: &ModelRequest) -> ToolResult {
    match request.messages.last().and_then(|m| m.parts.first()) {
        Some(ContentPart::ToolResult(r)) => r.clone(),
        other => panic!("missing tool result: {other:?}"),
    }
}

#[tokio::test]
async fn runs_tool_then_answers() {
    let provider = ScriptedProvider::new(vec![
        (
            call("set_inset", json!({"position": "bottomRight"}), "c1"),
            StopReason::ToolUse,
        ),
        (reply("Done."), StopReason::EndTurn),
    ]);
    let events = run(provider.clone(), None).await;
    let requests = provider.requests();
    assert_eq!(requests.len(), 2);
    let second = &requests[1].messages;
    assert_eq!(second.len(), 3);
    assert_eq!(second[2].role, ChatRole::Tool);
    assert_eq!(
        second[2].parts,
        [ContentPart::ToolResult(ToolResult::new(
            "c1",
            "set_inset",
            r#"{"ok":true}"#
        ))]
    );
    let names: Vec<String> = requests[0].tools.iter().map(|t| t.name.clone()).collect();
    assert_eq!(names, ["set_inset", "delete_take"]);
    assert!(needs_user(&events).is_empty());
    // Events in Swift's order.
    assert!(matches!(events[0], RunnerEvent::AssistantMessage { .. }));
    assert!(matches!(events[1], RunnerEvent::Usage(_)));
    assert!(matches!(events[2], RunnerEvent::ToolRunning(_)));
    assert!(matches!(events[3], RunnerEvent::ToolFinished(_, _)));
    assert!(matches!(events[4], RunnerEvent::ToolResults(_)));
    assert_eq!(events[5], RunnerEvent::TextDelta("Done.".into()));
}

#[tokio::test]
async fn retries_once_after_invalid_call() {
    let provider = ScriptedProvider::new(vec![
        (
            call("set_inset", json!({"position": "middle"}), "a"),
            StopReason::ToolUse,
        ),
        (
            call("set_inset", json!({"position": "topLeft"}), "b"),
            StopReason::ToolUse,
        ),
        (reply("Fixed."), StopReason::EndTurn),
    ]);
    let events = run(provider.clone(), None).await;
    let requests = provider.requests();
    assert_eq!(requests.len(), 3);
    let first = last_result(&requests[1]);
    assert!(first.is_error);
    assert!(first.content.contains("must be one of"));
    assert!(needs_user(&events).is_empty());
}

#[tokio::test]
async fn asks_user_after_second_invalid_call() {
    let provider = ScriptedProvider::new(vec![
        (
            call("set_inset", json!({"position": 1}), "a"),
            StopReason::ToolUse,
        ),
        (call("set_inset", json!({}), "b"), StopReason::ToolUse),
        (reply("never reached"), StopReason::EndTurn),
    ]);
    let events = run(provider.clone(), None).await;
    assert_eq!(provider.requests().len(), 2);
    let asks = needs_user(&events);
    assert_eq!(
        asks,
        [
            "The model couldn't make a valid call to set_inset after a retry. \
          Could you rephrase, pick a stronger model, or use the buttons instead?"
        ]
    );
}

#[tokio::test]
async fn destructive_tool_needs_confirmation() {
    let declined = ScriptedProvider::new(vec![
        (call("delete_take", json!({}), "d"), StopReason::ToolUse),
        (reply("ok"), StopReason::EndTurn),
    ]);
    run(declined.clone(), None).await;
    assert_eq!(
        last_result(&declined.requests()[1]).content,
        "The user declined this action."
    );

    let approved = ScriptedProvider::new(vec![
        (call("delete_take", json!({}), "d"), StopReason::ToolUse),
        (reply("ok"), StopReason::EndTurn),
    ]);
    let asked = Arc::new(Mutex::new(Vec::new()));
    let seen = asked.clone();
    let runner = ConversationRunner::new(approved.clone(), registry(), "m").with_confirm(
        move |call: ToolCall| {
            seen.lock().expect("lock").push(call.name);
            async { true }
        },
    );
    run(approved.clone(), Some(runner)).await;
    assert_eq!(
        last_result(&approved.requests()[1]).content,
        r#"{"deleted":true}"#
    );
    assert_eq!(*asked.lock().expect("lock"), ["delete_take"]);
}

#[tokio::test]
async fn truncated_tool_call_is_not_executed() {
    let provider = ScriptedProvider::new(vec![(
        call("set_inset", json!({"position": "topLeft"}), "t"),
        StopReason::MaxTokens,
    )]);
    let events = run(provider.clone(), None).await;
    assert_eq!(provider.requests().len(), 1);
    let results: Vec<&ChatMessage> = events
        .iter()
        .filter_map(|e| match e {
            RunnerEvent::ToolResults(m) => Some(m),
            _ => None,
        })
        .collect();
    let Some(ContentPart::ToolResult(r)) = results[0].parts.first() else {
        panic!("no result")
    };
    assert!(r.is_error);
    assert_eq!(r.content, "Not executed: the reply was cut off.");
    assert!(
        !events
            .iter()
            .any(|e| matches!(e, RunnerEvent::ToolRunning(_)))
    );
    assert_eq!(
        needs_user(&events),
        ["The reply was cut off before its tool call finished. Try a shorter request."]
    );
}

#[tokio::test]
async fn refusal_stops_and_asks() {
    let provider = ScriptedProvider::new(vec![(reply(""), StopReason::Refusal)]);
    let events = run(provider, None).await;
    assert_eq!(needs_user(&events), ["The model declined this request."]);
}

#[tokio::test]
async fn stops_after_max_rounds() {
    let turns = (0..20)
        .map(|i| {
            (
                call(
                    "set_inset",
                    json!({"position": "topLeft"}),
                    &format!("c{i}"),
                ),
                StopReason::ToolUse,
            )
        })
        .collect();
    let provider = ScriptedProvider::new(turns);
    let events = run(provider.clone(), None).await;
    assert_eq!(provider.requests().len(), 12);
    assert_eq!(
        needs_user(&events),
        ["Stopped after 12 tool rounds. Say \"continue\" to keep going."]
    );
    // History only grows: each request starts with the previous one.
    let requests = provider.requests();
    for pair in requests.windows(2) {
        assert_eq!(
            pair[1].messages[..pair[0].messages.len()],
            pair[0].messages[..]
        );
    }
}

#[tokio::test]
async fn provider_errors_end_the_stream() {
    let provider = ScriptedProvider::new(Vec::new());
    let runner = ConversationRunner::new(provider, registry(), "m");
    let events: Vec<_> = runner.run(vec![ChatMessage::user("go")]).collect().await;
    assert_eq!(
        events,
        [Err(ProviderError::MalformedResponse(
            "script exhausted".into()
        ))]
    );
}

#[tokio::test]
async fn dropping_the_stream_cancels_the_turn() {
    let ran = Arc::new(Mutex::new(false));
    let flag = ran.clone();
    let slow = ToolRegistry::new([RegisteredTool::new(
        "slow",
        "",
        json!({"type": "object"}),
        move |_| {
            let flag = flag.clone();
            async move {
                tokio::time::sleep(Duration::from_millis(200)).await;
                *flag.lock().expect("lock") = true;
                Ok(json!({}))
            }
        },
    )]);
    let provider = ScriptedProvider::new(vec![
        (call("slow", json!({}), "s"), StopReason::ToolUse),
        (reply("done"), StopReason::EndTurn),
    ]);
    let runner = ConversationRunner::new(provider.clone(), slow, "m");
    let mut stream = runner.run(vec![ChatMessage::user("go")]);
    // Read until the tool starts, then drop the stream.
    while let Some(event) = stream.next().await {
        if matches!(event, Ok(RunnerEvent::ToolRunning(_))) {
            break;
        }
    }
    drop(stream);
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(!*ran.lock().expect("lock"));
    assert_eq!(provider.requests().len(), 1);
}
