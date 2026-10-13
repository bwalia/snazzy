//! Local (or LAN) models via Ollama's `/api/chat`: NDJSON streaming with tools.

use std::time::Duration;

use futures_util::future::BoxFuture;
use serde_json::{Map, Value, json};
use uuid::Uuid;

use crate::base64;
use crate::json::int_value;
use crate::provider::{self, EventStream, LineParser, ModelProvider, channel_stream};
use crate::text_tool_calls;
use crate::types::{
    ChatMessage, ChatRole, ContentPart, ModelInfo, ModelRequest, ProviderError, ProviderKind,
    StopReason, StreamEvent, TokenUsage, ToolCall,
};

pub const DEFAULT_BASE_URL: &str = "http://localhost:11434";
/// Ollama's default context is small; tool schemas plus a conversation need more.
pub const CONTEXT_LENGTH: u32 = 32_768;
/// Tool calls and results older than this many messages are cut down, so a
/// long builder chat fits in `CONTEXT_LENGTH`.
pub const RECENT_MESSAGES: usize = 8;
pub const OLD_TEXT_LIMIT: usize = 1_500;

/// Cuts an old tool payload down to `OLD_TEXT_LIMIT` characters.
pub fn shortened(text: &str) -> String {
    let count = text.chars().count();
    if count <= OLD_TEXT_LIMIT {
        return text.to_string();
    }
    let head: String = text.chars().take(OLD_TEXT_LIMIT).collect();
    format!(
        "{head}\n… [{} more characters left out to save space; read_file shows the current file]",
        count - OLD_TEXT_LIMIT
    )
}

/// The `/api/chat` request body (Swift `OllamaMapping.requestBody`).
pub fn request_body(request: &ModelRequest) -> Value {
    let mut body = json!({
        "model": request.model,
        "stream": true,
        "messages": messages(request),
        "options": {"num_ctx": CONTEXT_LENGTH},
    });
    if !request.tools.is_empty() {
        let tools: Vec<Value> = request
            .tools
            .iter()
            .map(|tool| {
                json!({
                    "type": "function",
                    "function": {
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.input_schema,
                    },
                })
            })
            .collect();
        body["tools"] = Value::Array(tools);
    }
    body
}

/// Maps the history. Ollama has no thinking blocks to keep valid, so tool
/// payloads older than `RECENT_MESSAGES` are shortened here (only here).
pub fn messages(request: &ModelRequest) -> Vec<Value> {
    let mut out = Vec::new();
    if let Some(system) = request.system.as_deref().filter(|s| !s.is_empty()) {
        out.push(json!({"role": "system", "content": system}));
    }
    let first_recent = request.messages.len().saturating_sub(RECENT_MESSAGES);
    for (index, message) in request.messages.iter().enumerate() {
        let old = index < first_recent;
        match message.role {
            ChatRole::User => {
                let mut m = json!({"role": "user", "content": message.text()});
                let images = message.images();
                if !images.is_empty() {
                    m["images"] = images
                        .iter()
                        .map(|(_, data)| json!(base64::encode(data)))
                        .collect();
                }
                out.push(m);
            }
            ChatRole::Assistant => {
                let mut m = json!({"role": "assistant", "content": message.text()});
                let calls = message.tool_calls();
                if !calls.is_empty() {
                    m["tool_calls"] = calls
                        .iter()
                        .map(|call| {
                            let mut args = call.arguments.as_object().cloned().unwrap_or_default();
                            if old {
                                for value in args.values_mut() {
                                    if let Some(s) = value.as_str() {
                                        *value = Value::String(shortened(s));
                                    }
                                }
                            }
                            json!({"function": {"name": call.name, "arguments": args}})
                        })
                        .collect();
                }
                out.push(m);
            }
            ChatRole::Tool => {
                for part in &message.parts {
                    if let ContentPart::ToolResult(r) = part {
                        let content = if old {
                            shortened(&r.content)
                        } else {
                            r.content.clone()
                        };
                        out.push(json!({"role": "tool", "content": content, "tool_name": r.name}));
                    }
                }
            }
        }
    }
    out
}

/// Models from `/api/tags`.
pub fn models_from_tags(json: &Value) -> Vec<ModelInfo> {
    json.get("models")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|item| {
                    let name = item.get("name")?.as_str()?.to_string();
                    let caps = item.get("capabilities").and_then(Value::as_array);
                    let size = item
                        .get("details")
                        .and_then(|d| d.get("parameter_size"))
                        .and_then(Value::as_str);
                    Some(ModelInfo {
                        display_name: size
                            .map_or_else(|| name.clone(), |s| format!("{name} ({s})")),
                        supports_tools: caps.map(|c| c.iter().any(|v| v.as_str() == Some("tools"))),
                        id: name,
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

pub fn error_message(json: &Value) -> Option<String> {
    json.get("error")
        .and_then(Value::as_str)
        .map(str::to_string)
}

fn new_call_id() -> String {
    let id = Uuid::new_v4().simple().to_string();
    format!("call_{}", &id[..8])
}

/// Ollama on this computer or another one.
#[derive(Debug)]
pub struct OllamaProvider {
    base_url: String,
    client: reqwest::Client,
}

impl OllamaProvider {
    pub fn new(base_url: &str) -> Result<Self, ProviderError> {
        let base_url = provider::validate_base_url(base_url)?;
        // Large local models can take minutes to load.
        let client = reqwest::Client::builder()
            .read_timeout(Duration::from_secs(900))
            .build()
            .map_err(|e| ProviderError::Unreachable(e.to_string()))?;
        Ok(Self { base_url, client })
    }

    pub fn base_url(&self) -> &str {
        &self.base_url
    }
}

impl ModelProvider for OllamaProvider {
    fn kind(&self) -> ProviderKind {
        ProviderKind::Ollama
    }

    fn list_models(&self) -> BoxFuture<'_, Result<Vec<ModelInfo>, ProviderError>> {
        Box::pin(async move {
            let url = format!("{}/api/tags", self.base_url);
            let request = self.client.get(&url).timeout(Duration::from_secs(10));
            let json = provider::data(request, &url, error_message).await?;
            Ok(models_from_tags(&json))
        })
    }

    fn stream(&self, request: ModelRequest) -> EventStream {
        let url = format!("{}/api/chat", self.base_url);
        let builder = self
            .client
            .post(&url)
            .header("content-type", "application/json")
            .body(request_body(&request).to_string());
        tracing::info!(
            target: "provider",
            model = %request.model,
            messages = request.messages.len(),
            "Ollama request"
        );
        channel_stream(move |emit| async move {
            let result = async {
                let response = provider::send(builder, &url, error_message).await?;
                provider::pump_lines(response, &url, OllamaStreamParser::new(), &emit).await
            }
            .await;
            if let Err(error) = result {
                tracing::error!(target: "provider", "Ollama stream failed: {error}");
                emit.emit(Err(error));
            }
        })
    }
}

/// Accumulates `/api/chat` NDJSON chunks.
#[derive(Debug, Clone, Default)]
pub struct OllamaStreamParser {
    text: String,
    tool_calls: Vec<ToolCall>,
    usage: TokenUsage,
    done_reason: Option<String>,
    model: Option<String>,
    finished: bool,
}

impl OllamaStreamParser {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn is_finished(&self) -> bool {
        self.finished
    }

    pub fn consume(&mut self, line: &str) -> Result<Vec<StreamEvent>, ProviderError> {
        let trimmed = line.trim_matches([' ', '\t']);
        if trimmed.is_empty() {
            return Ok(Vec::new());
        }
        let chunk: Value = serde_json::from_str(trimmed).map_err(|_| {
            ProviderError::MalformedResponse(format!(
                "bad NDJSON: {}",
                trimmed.chars().take(200).collect::<String>()
            ))
        })?;
        if let Some(error) = chunk.get("error").and_then(Value::as_str) {
            return Err(ProviderError::Api {
                error_type: "ollama".into(),
                message: error.to_string(),
            });
        }
        if let Some(model) = chunk.get("model").and_then(Value::as_str) {
            self.model = Some(model.to_string());
        }

        let mut events = Vec::new();
        if let Some(message) = chunk.get("message") {
            if let Some(thinking) = message
                .get("thinking")
                .and_then(Value::as_str)
                .filter(|t| !t.is_empty())
            {
                events.push(StreamEvent::ThinkingDelta(thinking.to_string()));
            }
            if let Some(content) = message
                .get("content")
                .and_then(Value::as_str)
                .filter(|t| !t.is_empty())
            {
                self.text.push_str(content);
                events.push(StreamEvent::TextDelta(content.to_string()));
            }
            for call in message
                .get("tool_calls")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
            {
                let Some(function) = call.get("function") else {
                    continue;
                };
                let Some(name) = function.get("name").and_then(Value::as_str) else {
                    continue;
                };
                let mut args = function
                    .get("arguments")
                    .cloned()
                    .unwrap_or_else(|| Value::Object(Map::new()));
                // Some models send arguments as a JSON string.
                if let Some(parsed) = args.as_str().and_then(|s| serde_json::from_str(s).ok()) {
                    args = parsed;
                }
                let id = call
                    .get("id")
                    .and_then(Value::as_str)
                    .map_or_else(new_call_id, str::to_string);
                self.tool_calls.push(ToolCall::new(id, name, args));
                events.push(StreamEvent::ToolCallStarted {
                    name: name.to_string(),
                });
            }
        }
        if chunk.get("done").and_then(Value::as_bool) == Some(true) {
            self.finished = true;
            self.done_reason = chunk
                .get("done_reason")
                .and_then(Value::as_str)
                .map(str::to_string);
            self.usage = TokenUsage {
                input_tokens: chunk
                    .get("prompt_eval_count")
                    .and_then(int_value)
                    .unwrap_or(0),
                output_tokens: chunk.get("eval_count").and_then(int_value).unwrap_or(0),
            };
        }
        Ok(events)
    }

    pub fn completion(&self) -> StreamEvent {
        let mut text = self.text.clone();
        let mut tool_calls = self.tool_calls.clone();
        // A model that wrote its tool call as text: run it anyway.
        let found = if tool_calls.is_empty() {
            text_tool_calls::extract(&text)
        } else {
            None
        };
        if let Some((cleaned, calls)) = found {
            text = cleaned;
            tool_calls = calls
                .into_iter()
                .map(|c| ToolCall::new(new_call_id(), c.name, c.arguments))
                .collect();
        } else {
            text = text_tool_calls::without_stray_markup(&text);
        }
        let mut parts = Vec::new();
        if !text.is_empty() {
            parts.push(ContentPart::Text(text));
        }
        let has_calls = !tool_calls.is_empty();
        parts.extend(tool_calls.into_iter().map(ContentPart::ToolCall));
        let stop_reason = if has_calls {
            StopReason::ToolUse
        } else if self.done_reason.as_deref() == Some("length") {
            StopReason::MaxTokens
        } else {
            StopReason::EndTurn
        };
        StreamEvent::Completed {
            message: ChatMessage::new(ChatRole::Assistant, parts),
            stop_reason,
            usage: self.usage,
            served_by: self.model.clone(),
        }
    }
}

impl LineParser for OllamaStreamParser {
    fn consume_line(&mut self, line: &str) -> Result<Vec<StreamEvent>, ProviderError> {
        self.consume(line)
    }
    fn is_finished(&self) -> bool {
        self.finished
    }
    fn completion(&self) -> StreamEvent {
        OllamaStreamParser::completion(self)
    }
}
