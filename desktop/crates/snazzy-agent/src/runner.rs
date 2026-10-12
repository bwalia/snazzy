//! Runs one user turn (Swift `ConversationRunner`): streams the model, runs
//! its tool calls, sends the results back, and repeats until the model stops
//! calling tools.
//!
//! An invalid tool call gets one retry with the validation error; a second
//! invalid round in a row stops and asks the user. History is append-only, so
//! thinking blocks stay valid.

use std::future::Future;
use std::sync::Arc;

use futures_util::future::BoxFuture;
use futures_util::stream::{BoxStream, StreamExt};

use crate::provider::{Emitter, ModelProvider, channel_stream};
use crate::tools::{ToolRegistry, invalid_result};
use crate::types::{
    ChatMessage, ChatRole, ContentPart, ModelRequest, ProviderError, StopReason, StreamEvent,
    TokenUsage, ToolCall, ToolResult,
};

#[derive(Debug, Clone, PartialEq)]
pub enum RunnerEvent {
    TextDelta(String),
    ThinkingDelta(String),
    ToolCallStarted {
        name: String,
    },
    ToolInputDelta {
        call_id: String,
        name: String,
        fragment: String,
    },
    /// A tool is about to run (after validation and confirmation).
    ToolRunning(ToolCall),
    /// A finished assistant message to append to the history.
    AssistantMessage {
        message: ChatMessage,
        stop_reason: StopReason,
        served_by: Option<String>,
    },
    ToolFinished(ToolCall, ToolResult),
    /// Tool results to append to the history.
    ToolResults(ChatMessage),
    Usage(TokenUsage),
    /// The loop stopped and needs the user (bad tool calls, refusal, truncation).
    NeedsUser(String),
}

/// Asks the user to confirm a tool marked `requires_confirmation`.
pub type ConfirmFn = Arc<dyn Fn(ToolCall) -> BoxFuture<'static, bool> + Send + Sync>;

pub const DEFAULT_MAX_TOOL_ROUNDS: usize = 12;

pub const DECLINED: &str = "The user declined this action.";

#[derive(Clone)]
pub struct ConversationRunner {
    pub provider: Arc<dyn ModelProvider>,
    pub registry: ToolRegistry,
    pub model: String,
    pub system: Option<String>,
    pub max_tokens: u32,
    pub effort: Option<String>,
    pub max_tool_rounds: usize,
    /// Declines everything unless the caller supplies one.
    pub confirm: ConfirmFn,
}

impl ConversationRunner {
    pub fn new(
        provider: Arc<dyn ModelProvider>,
        registry: ToolRegistry,
        model: impl Into<String>,
    ) -> Self {
        Self {
            provider,
            registry,
            model: model.into(),
            system: None,
            max_tokens: ModelRequest::DEFAULT_MAX_TOKENS,
            effort: None,
            max_tool_rounds: DEFAULT_MAX_TOOL_ROUNDS,
            confirm: Arc::new(|_| Box::pin(async { false })),
        }
    }

    pub fn with_system(mut self, system: impl Into<String>) -> Self {
        self.system = Some(system.into());
        self
    }

    pub fn with_effort(mut self, effort: impl Into<String>) -> Self {
        self.effort = Some(effort.into());
        self
    }

    pub fn with_confirm<F, Fut>(mut self, confirm: F) -> Self
    where
        F: Fn(ToolCall) -> Fut + Send + Sync + 'static,
        Fut: Future<Output = bool> + Send + 'static,
    {
        self.confirm = Arc::new(move |call| Box::pin(confirm(call)));
        self
    }

    /// Runs the turn. Dropping the stream cancels it (and the HTTP request).
    pub fn run(
        &self,
        history: Vec<ChatMessage>,
    ) -> BoxStream<'static, Result<RunnerEvent, ProviderError>> {
        let runner = self.clone();
        channel_stream(
            move |emit: Emitter<Result<RunnerEvent, ProviderError>>| async move {
                let send = |event: RunnerEvent| emit.emit(Ok(event));
                if let Err(error) = runner.run_loop(history, &send).await {
                    emit.emit(Err(error));
                }
            },
        )
    }

    async fn run_loop(
        &self,
        history: Vec<ChatMessage>,
        emit: &(dyn Fn(RunnerEvent) + Send + Sync),
    ) -> Result<(), ProviderError> {
        let mut messages = history;
        let mut invalid_rounds = 0;

        for _ in 0..self.max_tool_rounds {
            let request = ModelRequest {
                model: self.model.clone(),
                system: self.system.clone(),
                messages: messages.clone(),
                tools: self.registry.definitions(),
                max_tokens: self.max_tokens,
                effort: self.effort.clone(),
            };

            let mut completed = None;
            let mut stream = self.provider.stream(request);
            while let Some(event) = stream.next().await {
                match event? {
                    StreamEvent::TextDelta(t) => emit(RunnerEvent::TextDelta(t)),
                    StreamEvent::ThinkingDelta(t) => emit(RunnerEvent::ThinkingDelta(t)),
                    StreamEvent::ToolCallStarted { name } => {
                        emit(RunnerEvent::ToolCallStarted { name })
                    }
                    StreamEvent::ToolInputDelta {
                        call_id,
                        name,
                        fragment,
                    } => emit(RunnerEvent::ToolInputDelta {
                        call_id,
                        name,
                        fragment,
                    }),
                    StreamEvent::Completed {
                        message,
                        stop_reason,
                        usage,
                        served_by,
                    } => completed = Some((message, stop_reason, usage, served_by)),
                }
            }
            drop(stream);
            let Some((assistant, stop, usage, served_by)) = completed else {
                return Err(ProviderError::MalformedResponse(
                    "stream ended without a message".into(),
                ));
            };
            messages.push(assistant.clone());
            let calls = assistant.tool_calls();
            emit(RunnerEvent::AssistantMessage {
                message: assistant,
                stop_reason: stop.clone(),
                served_by,
            });
            emit(RunnerEvent::Usage(usage));

            if calls.is_empty() {
                if stop == StopReason::Refusal {
                    emit(RunnerEvent::NeedsUser(
                        "The model declined this request.".into(),
                    ));
                }
                if stop == StopReason::MaxTokens {
                    emit(RunnerEvent::NeedsUser(
                        "The reply hit the output limit and was cut off.".into(),
                    ));
                }
                return Ok(());
            }

            // A cut-off or refused turn can carry a partial tool call: never run
            // it, but answer every call so the history stays valid.
            if stop == StopReason::MaxTokens || stop == StopReason::Refusal {
                let reason = if stop == StopReason::Refusal {
                    "the model declined"
                } else {
                    "the reply was cut off"
                };
                let parts = calls
                    .iter()
                    .map(|c| {
                        ContentPart::ToolResult(ToolResult::error(
                            &c.id,
                            &c.name,
                            format!("Not executed: {reason}."),
                        ))
                    })
                    .collect();
                emit(RunnerEvent::ToolResults(ChatMessage::new(
                    ChatRole::Tool,
                    parts,
                )));
                emit(RunnerEvent::NeedsUser(if stop == StopReason::Refusal {
                    "The model declined this request.".into()
                } else {
                    "The reply was cut off before its tool call finished. Try a shorter request."
                        .into()
                }));
                return Ok(());
            }

            let mut results = Vec::new();
            let mut invalid_calls: Vec<&ToolCall> = Vec::new();
            for call in &calls {
                let errors = self.registry.validate(call);
                let tool = self.registry.tool(&call.name);
                let result = if !errors.is_empty() {
                    invalid_calls.push(call);
                    tracing::info!(
                        target: "assistant",
                        "Invalid tool call {}: {}",
                        call.name,
                        errors.join("; ")
                    );
                    invalid_result(call, &errors, tool.map(|t| &t.definition.input_schema))
                } else if tool.is_some_and(|t| t.requires_confirmation)
                    && !(self.confirm)(call.clone()).await
                {
                    ToolResult::error(&call.id, &call.name, DECLINED)
                } else {
                    emit(RunnerEvent::ToolRunning(call.clone()));
                    self.registry.execute(call).await
                };
                emit(RunnerEvent::ToolFinished(call.clone(), result.clone()));
                results.push(result);
            }
            let result_message = ChatMessage::new(
                ChatRole::Tool,
                results.into_iter().map(ContentPart::ToolResult).collect(),
            );
            messages.push(result_message.clone());
            emit(RunnerEvent::ToolResults(result_message));

            if invalid_calls.is_empty() {
                invalid_rounds = 0;
            } else {
                invalid_rounds += 1;
                if invalid_rounds >= 2 {
                    let mut names: Vec<&str> =
                        invalid_calls.iter().map(|c| c.name.as_str()).collect();
                    names.sort_unstable();
                    names.dedup();
                    emit(RunnerEvent::NeedsUser(format!(
                        "The model couldn't make a valid call to {} after a retry. \
                         Could you rephrase, pick a stronger model, or use the buttons instead?",
                        names.join(", ")
                    )));
                    return Ok(());
                }
            }
        }
        emit(RunnerEvent::NeedsUser(format!(
            "Stopped after {} tool rounds. Say \"continue\" to keep going.",
            self.max_tool_rounds
        )));
        Ok(())
    }
}
