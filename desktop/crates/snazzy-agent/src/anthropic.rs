//! Claude via the Messages API (`POST /v1/messages`), streamed over SSE.
//!
//! History is sent exactly as stored: never edited or trimmed here, because
//! that invalidates thinking blocks. Long-context relief is server-side
//! (`context_management`), and prompt caching is the top-level `cache_control`.

use std::collections::HashMap;
use std::time::Duration;

use futures_util::future::BoxFuture;
use serde_json::{Map, Value, json};
use uuid::Uuid;

use crate::base64;
use crate::json::{compact_string, int_value};
use crate::provider::{self, EventStream, LineParser, ModelProvider, channel_stream};
use crate::types::{
    ChatMessage, ChatRole, ContentPart, ModelInfo, ModelRequest, ProviderError, ProviderKind,
    StopReason, StreamEvent, TokenUsage, ToolCall,
};

/// Default model for planning, writing and building.
pub const DEFAULT_MODEL: &str = "claude-opus-5-5";
/// Default model for quick commands.
pub const QUICK_MODEL: &str = "claude-sonnet-5-5";
pub const DEFAULT_BASE_URL: &str = "https://api.anthropic.com";

pub const API_VERSION: &str = "2023-06-01";
pub const FALLBACK_BETA: &str = "server-side-fallback-2026-07-01";
pub const CONTEXT_MANAGEMENT_BETA: &str = "context-management-2025-06-27";

/// Models that accept `fallbacks: "default"`.
pub fn supports_default_fallbacks(model: &str) -> bool {
    [
        "claude-opus-5-5",
        "claude-opus-5",
        "claude-fable-5-1",
        "claude-sonnet-5-5",
    ]
    .contains(&model)
}

/// The `anthropic-beta` values sent for a model.
pub fn betas(model: &str) -> Vec<&'static str> {
    let mut out = Vec::new();
    if supports_default_fallbacks(model) {
        out.push(FALLBACK_BETA);
    }
    out.push(CONTEXT_MANAGEMENT_BETA);
    out
}

/// The Messages API request body (Swift `AnthropicMapping.requestBody`).
pub fn request_body(request: &ModelRequest) -> Value {
    let mut body = json!({
        "model": request.model,
        "max_tokens": request.max_tokens,
        "stream": true,
        "messages": messages(&request.messages),
        // Adaptive thinking with readable summaries, shown collapsed in the chat.
        "thinking": {"type": "adaptive", "display": "summarized"},
        // Cache everything up to the newest turn (tools, system, history).
        "cache_control": {"type": "ephemeral"},
        // Long chats: once the prompt is large, the API clears old tool calls and
        // results, keeping the latest few. Server-side, because trimming history
        // here would invalidate thinking blocks.
        "context_management": {"edits": [{
            "type": "clear_tool_uses_20250919",
            "trigger": {"type": "input_tokens", "value": 150_000},
            "keep": {"type": "tool_uses", "value": 6},
            "clear_at_least": {"type": "input_tokens", "value": 40_000},
            "clear_tool_inputs": true,
        }]},
    });
    let object = body.as_object_mut().expect("object literal");
    if let Some(system) = request.system.as_deref().filter(|s| !s.is_empty()) {
        object.insert("system".into(), json!(system));
    }
    if let Some(effort) = &request.effort {
        object.insert("output_config".into(), json!({"effort": effort}));
    }
    if supports_default_fallbacks(&request.model) {
        object.insert("fallbacks".into(), json!("default"));
    }
    if !request.tools.is_empty() {
        let tools: Vec<Value> = request
            .tools
            .iter()
            .map(|tool| {
                json!({
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": tool.input_schema,
                    "eager_input_streaming": true,
                })
            })
            .collect();
        object.insert("tools".into(), Value::Array(tools));
    }
    body
}

/// Maps the history to API messages. Tool results become user turns, and
/// consecutive turns with the same API role are merged into one.
pub fn messages(history: &[ChatMessage]) -> Vec<Value> {
    let mut result: Vec<(&'static str, Vec<Value>)> = Vec::new();
    for message in history {
        let role = if message.role == ChatRole::Assistant {
            "assistant"
        } else {
            "user"
        };
        let blocks: Vec<Value> = message.parts.iter().filter_map(block).collect();
        if blocks.is_empty() {
            continue;
        }
        match result.last_mut() {
            Some((last, existing)) if *last == role => existing.extend(blocks),
            _ => result.push((role, blocks)),
        }
    }
    result
        .into_iter()
        .map(|(role, blocks)| json!({"role": role, "content": blocks}))
        .collect()
}

/// One content block; `None` for parts this provider doesn't take.
pub fn block(part: &ContentPart) -> Option<Value> {
    match part {
        ContentPart::Text(text) => {
            (!text.is_empty()).then(|| json!({"type": "text", "text": text}))
        }
        ContentPart::ToolCall(call) => {
            let input = if call.arguments.is_object() {
                call.arguments.clone()
            } else {
                json!({})
            };
            Some(json!({"type": "tool_use", "id": call.id, "name": call.name, "input": input}))
        }
        ContentPart::ToolResult(result) => Some(json!({
            "type": "tool_result",
            "tool_use_id": result.call_id,
            "content": result.content,
            "is_error": result.is_error,
        })),
        // Echoed back exactly as received.
        ContentPart::Opaque { provider, block } => {
            (*provider == ProviderKind::Anthropic).then(|| block.clone())
        }
        ContentPart::Image { media_type, data } => Some(json!({
            "type": "image",
            "source": {"type": "base64", "media_type": media_type, "data": base64::encode(data)},
        })),
    }
}

/// The message of an API error body (`{"error":{"type","message"}}`).
pub fn error_message(json: &Value) -> Option<String> {
    let error = json.get("error")?;
    let kind = error.get("type").and_then(Value::as_str).unwrap_or("error");
    let message = error
        .get("message")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    Some(format!("{kind}: {message}"))
}

/// Claude over the Messages API. The API key is given by the caller and is
/// never logged or shown by `Debug`.
pub struct AnthropicProvider {
    base_url: String,
    api_key: String,
    client: reqwest::Client,
}

impl std::fmt::Debug for AnthropicProvider {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AnthropicProvider")
            .field("base_url", &self.base_url)
            .finish_non_exhaustive()
    }
}

impl AnthropicProvider {
    pub fn new(api_key: impl Into<String>) -> Result<Self, ProviderError> {
        Self::with_base_url(api_key, DEFAULT_BASE_URL)
    }

    pub fn with_base_url(
        api_key: impl Into<String>,
        base_url: &str,
    ) -> Result<Self, ProviderError> {
        let api_key = api_key.into();
        if api_key.is_empty() {
            return Err(ProviderError::MissingApiKey(ProviderKind::Anthropic));
        }
        let base_url = provider::validate_base_url(base_url)?;
        let client = reqwest::Client::builder()
            .read_timeout(Duration::from_secs(600))
            .build()
            .map_err(|e| ProviderError::Unreachable(e.to_string()))?;
        Ok(Self {
            base_url,
            api_key,
            client,
        })
    }

    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    fn request(
        &self,
        method: reqwest::Method,
        url: &str,
        betas: &[&str],
    ) -> reqwest::RequestBuilder {
        let mut builder = self
            .client
            .request(method, url)
            .header("x-api-key", &self.api_key)
            .header("anthropic-version", API_VERSION)
            .header("content-type", "application/json");
        if !betas.is_empty() {
            builder = builder.header("anthropic-beta", betas.join(","));
        }
        builder
    }
}

impl ModelProvider for AnthropicProvider {
    fn kind(&self) -> ProviderKind {
        ProviderKind::Anthropic
    }

    fn list_models(&self) -> BoxFuture<'_, Result<Vec<ModelInfo>, ProviderError>> {
        Box::pin(async move {
            let url = format!("{}/v1/models", self.base_url);
            let request = self.request(reqwest::Method::GET, &url, &[]);
            let json = provider::data(request, &url, error_message).await?;
            Ok(json
                .get("data")
                .and_then(Value::as_array)
                .map(|items| {
                    items
                        .iter()
                        .filter_map(|item| {
                            let id = item.get("id")?.as_str()?.to_string();
                            let display_name = item
                                .get("display_name")
                                .and_then(Value::as_str)
                                .map_or_else(|| id.clone(), str::to_string);
                            Some(ModelInfo {
                                id,
                                display_name,
                                supports_tools: Some(true),
                            })
                        })
                        .collect()
                })
                .unwrap_or_default())
        })
    }

    fn stream(&self, request: ModelRequest) -> EventStream {
        let url = format!("{}/v1/messages", self.base_url);
        let builder = self
            .request(reqwest::Method::POST, &url, &betas(&request.model))
            .body(request_body(&request).to_string());
        tracing::info!(
            target: "provider",
            model = %request.model,
            messages = request.messages.len(),
            "Anthropic request"
        );
        channel_stream(move |emit| async move {
            let result = async {
                let response = provider::send(builder, &url, error_message).await?;
                provider::pump_lines(response, &url, AnthropicStreamParser::new(), &emit).await
            }
            .await;
            if let Err(error) = result {
                tracing::error!(target: "provider", "Anthropic stream failed: {error}");
                emit.emit(Err(error));
            }
        })
    }
}

#[derive(Debug, Clone)]
struct Block {
    start: Map<String, Value>,
    text: String,
    partial_json: String,
    thinking: String,
    signature: String,
}

impl Block {
    fn kind(&self) -> &str {
        self.start.get("type").and_then(Value::as_str).unwrap_or("")
    }

    fn start_str(&self, key: &str) -> Option<&str> {
        self.start.get(key).and_then(Value::as_str)
    }
}

/// Accumulates Messages API SSE events into deltas and a final assistant message.
#[derive(Debug, Clone, Default)]
pub struct AnthropicStreamParser {
    blocks: HashMap<i64, Block>,
    order: Vec<i64>,
    usage: TokenUsage,
    stop_reason: Option<String>,
    model: Option<String>,
    finished: bool,
}

impl AnthropicStreamParser {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn is_finished(&self) -> bool {
        self.finished
    }

    /// Feeds one SSE line. Only `data:` lines matter: every payload carries
    /// its own `type`, so `event:` lines are redundant.
    pub fn consume_sse_line(&mut self, line: &str) -> Result<Vec<StreamEvent>, ProviderError> {
        let Some(payload) = line.strip_prefix("data:") else {
            return Ok(Vec::new());
        };
        let payload = payload.trim_matches([' ', '\t']);
        if payload.is_empty() {
            return Ok(Vec::new());
        }
        let event: Value = serde_json::from_str(payload).map_err(|_| {
            ProviderError::MalformedResponse(format!(
                "bad SSE data: {}",
                payload.chars().take(200).collect::<String>()
            ))
        })?;
        self.consume_event(&event)
    }

    pub fn consume_event(&mut self, event: &Value) -> Result<Vec<StreamEvent>, ProviderError> {
        let str_at = |v: Option<&Value>, key: &str| -> Option<String> {
            v.and_then(|v| v.get(key))
                .and_then(Value::as_str)
                .map(str::to_string)
        };
        match event.get("type").and_then(Value::as_str) {
            Some("message_start") => {
                let message = event.get("message");
                self.model = str_at(message, "model");
                if let Some(usage) = message.and_then(|m| m.get("usage")) {
                    self.apply_usage(usage);
                }
                Ok(Vec::new())
            }
            Some("content_block_start") => {
                let (Some(index), Some(start)) = (
                    event.get("index").and_then(int_value),
                    event.get("content_block").and_then(Value::as_object),
                ) else {
                    return Ok(Vec::new());
                };
                let block = Block {
                    start: start.clone(),
                    text: String::new(),
                    partial_json: String::new(),
                    thinking: String::new(),
                    signature: String::new(),
                };
                let is_tool = block.kind() == "tool_use";
                let name = block.start_str("name").unwrap_or("tool").to_string();
                self.blocks.insert(index, block);
                self.order.push(index);
                Ok(if is_tool {
                    vec![StreamEvent::ToolCallStarted { name }]
                } else {
                    Vec::new()
                })
            }
            Some("content_block_delta") => {
                let (Some(index), Some(delta)) =
                    (event.get("index").and_then(int_value), event.get("delta"))
                else {
                    return Ok(Vec::new());
                };
                let Some(block) = self.blocks.get_mut(&index) else {
                    return Ok(Vec::new());
                };
                let field = |key: &str| {
                    delta
                        .get(key)
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string()
                };
                Ok(match delta.get("type").and_then(Value::as_str) {
                    Some("text_delta") => {
                        let text = field("text");
                        block.text.push_str(&text);
                        vec![StreamEvent::TextDelta(text)]
                    }
                    Some("input_json_delta") => {
                        let fragment = field("partial_json");
                        block.partial_json.push_str(&fragment);
                        if fragment.is_empty() {
                            Vec::new()
                        } else {
                            vec![StreamEvent::ToolInputDelta {
                                call_id: block.start_str("id").unwrap_or("").to_string(),
                                name: block.start_str("name").unwrap_or("").to_string(),
                                fragment,
                            }]
                        }
                    }
                    Some("thinking_delta") => {
                        let text = field("thinking");
                        block.thinking.push_str(&text);
                        if text.is_empty() {
                            Vec::new()
                        } else {
                            vec![StreamEvent::ThinkingDelta(text)]
                        }
                    }
                    Some("signature_delta") => {
                        block.signature.push_str(&field("signature"));
                        Vec::new()
                    }
                    _ => Vec::new(),
                })
            }
            Some("message_delta") => {
                if let Some(reason) = str_at(event.get("delta"), "stop_reason") {
                    self.stop_reason = Some(reason);
                }
                if let Some(usage) = event.get("usage") {
                    self.apply_usage(usage);
                    let n = |k: &str| usage.get(k).and_then(int_value).unwrap_or(0);
                    // Shows whether prompt caching works (reads should grow turn by turn).
                    tracing::info!(
                        target: "provider",
                        "Anthropic usage: input {}, cache read {}, cache write {}",
                        n("input_tokens"),
                        n("cache_read_input_tokens"),
                        n("cache_creation_input_tokens")
                    );
                }
                if let Some(edits) = event
                    .get("context_management")
                    .and_then(|c| c.get("applied_edits"))
                    .filter(|e| e.as_array().is_some_and(|a| !a.is_empty()))
                {
                    tracing::info!(
                        target: "provider",
                        "Anthropic cleared old tool uses: {}",
                        compact_string(edits)
                    );
                }
                Ok(Vec::new())
            }
            Some("message_stop") => {
                self.finished = true;
                Ok(Vec::new())
            }
            Some("error") => {
                let error = event.get("error");
                Err(ProviderError::Api {
                    error_type: str_at(error, "type").unwrap_or_else(|| "error".into()),
                    message: str_at(error, "message").unwrap_or_else(|| "stream error".into()),
                })
            }
            // ping and future event types
            _ => Ok(Vec::new()),
        }
    }

    fn apply_usage(&mut self, usage: &Value) {
        let n = |k: &str| usage.get(k).and_then(int_value).unwrap_or(0);
        let input =
            n("input_tokens") + n("cache_creation_input_tokens") + n("cache_read_input_tokens");
        if input > 0 {
            self.usage.input_tokens = input;
        }
        if let Some(output) = usage.get("output_tokens").and_then(int_value) {
            self.usage.output_tokens = output;
        }
    }

    /// The assembled assistant message, in block order.
    pub fn completion(&self) -> StreamEvent {
        let mut parts = Vec::new();
        for index in &self.order {
            let Some(block) = self.blocks.get(index) else {
                continue;
            };
            match block.kind() {
                "text" => parts.push(ContentPart::Text(block.text.clone())),
                "tool_use" => {
                    let raw = block.partial_json.trim();
                    let arguments = if raw.is_empty() {
                        block.start.get("input").cloned().unwrap_or_else(|| json!({}))
                    } else {
                        // Unparseable (e.g. truncated) input is kept as a string so
                        // schema validation rejects it and the model can retry.
                        serde_json::from_str(raw).unwrap_or_else(|_| Value::String(raw.to_string()))
                    };
                    parts.push(ContentPart::ToolCall(ToolCall {
                        id: block
                            .start_str("id")
                            .map_or_else(|| Uuid::new_v4().to_string().to_uppercase(), str::to_string),
                        name: block.start_str("name").unwrap_or("").to_string(),
                        arguments,
                    }));
                }
                // Echoed back unchanged on the next request.
                "thinking" => parts.push(ContentPart::Opaque {
                    provider: ProviderKind::Anthropic,
                    block: json!({"type": "thinking", "thinking": block.thinking, "signature": block.signature}),
                }),
                // redacted_thinking, fallback markers and future block types.
                _ => parts.push(ContentPart::Opaque {
                    provider: ProviderKind::Anthropic,
                    block: Value::Object(block.start.clone()),
                }),
            }
        }
        StreamEvent::Completed {
            message: ChatMessage::new(ChatRole::Assistant, parts),
            stop_reason: StopReason::from_anthropic(self.stop_reason.as_deref()),
            usage: self.usage,
            served_by: self.model.clone(),
        }
    }
}

impl LineParser for AnthropicStreamParser {
    fn consume_line(&mut self, line: &str) -> Result<Vec<StreamEvent>, ProviderError> {
        self.consume_sse_line(line)
    }
    fn is_finished(&self) -> bool {
        self.finished
    }
    fn completion(&self) -> StreamEvent {
        AnthropicStreamParser::completion(self)
    }
}
