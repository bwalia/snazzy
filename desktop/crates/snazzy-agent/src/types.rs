//! Provider-neutral chat types (Swift `ChatTypes.swift`). The serde form of
//! `ChatMessage` is the one Swift's `Codable` writes, so conversations saved by
//! either app can be read by the other.

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::Value;
use uuid::Uuid;

use crate::base64;

/// A model backend family. Raw values match Swift `ProviderKind`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ProviderKind {
    /// Apple's on-device model. Only on the Mac; kept so shared histories decode.
    #[serde(rename = "appleOnDevice")]
    AppleOnDevice,
    #[serde(rename = "anthropic")]
    Anthropic,
    #[serde(rename = "ollama")]
    Ollama,
}

impl ProviderKind {
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::AppleOnDevice => "appleOnDevice",
            Self::Anthropic => "anthropic",
            Self::Ollama => "ollama",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::AppleOnDevice => "Apple Intelligence (on-device)",
            Self::Anthropic => "Anthropic",
            Self::Ollama => "Ollama (local)",
        }
    }

    /// The provider *type* is local. Whether content leaves this computer is
    /// decided by [`crate::settings::runs_on_this_computer`], never by this.
    pub fn is_local(self) -> bool {
        !matches!(self, Self::Anthropic)
    }

    /// Credential-store account for providers that need an API key.
    pub fn keychain_account(self) -> Option<&'static str> {
        match self {
            Self::Anthropic => Some("anthropic"),
            _ => None,
        }
    }

    pub fn suggested_models(self) -> &'static [&'static str] {
        match self {
            Self::AppleOnDevice => &["apple-on-device"],
            Self::Anthropic => &[
                crate::anthropic::DEFAULT_MODEL,
                crate::anthropic::QUICK_MODEL,
            ],
            Self::Ollama => &[],
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ChatRole {
    User,
    Assistant,
    /// Tool results. Anthropic gets them as a user turn, Ollama as role "tool".
    Tool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ToolCall {
    pub id: String,
    pub name: String,
    pub arguments: Value,
}

impl ToolCall {
    pub fn new(id: impl Into<String>, name: impl Into<String>, arguments: Value) -> Self {
        Self {
            id: id.into(),
            name: name.into(),
            arguments,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ToolResult {
    #[serde(rename = "callID")]
    pub call_id: String,
    pub name: String,
    pub content: String,
    #[serde(rename = "isError", default)]
    pub is_error: bool,
}

impl ToolResult {
    pub fn new(
        call_id: impl Into<String>,
        name: impl Into<String>,
        content: impl Into<String>,
    ) -> Self {
        Self {
            call_id: call_id.into(),
            name: name.into(),
            content: content.into(),
            is_error: false,
        }
    }

    pub fn error(
        call_id: impl Into<String>,
        name: impl Into<String>,
        content: impl Into<String>,
    ) -> Self {
        Self {
            is_error: true,
            ..Self::new(call_id, name, content)
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum ContentPart {
    Text(String),
    ToolCall(ToolCall),
    ToolResult(ToolResult),
    /// A provider-specific block echoed back unchanged to the same provider
    /// (Anthropic thinking blocks with signatures) and dropped for others.
    Opaque {
        provider: ProviderKind,
        block: Value,
    },
    /// An attached PNG/JPEG for providers that accept images.
    Image {
        media_type: String,
        data: Vec<u8>,
    },
}

/// Swift's synthesized `Codable` for enums with associated values:
/// `{"text":{"_0":"hi"}}`, `{"opaque":{"provider":"anthropic","block":{…}}}`.
#[derive(Serialize, Deserialize)]
enum WirePart {
    #[serde(rename = "text")]
    Text {
        #[serde(rename = "_0")]
        value: String,
    },
    #[serde(rename = "toolCall")]
    ToolCall {
        #[serde(rename = "_0")]
        value: ToolCall,
    },
    #[serde(rename = "toolResult")]
    ToolResult {
        #[serde(rename = "_0")]
        value: ToolResult,
    },
    #[serde(rename = "opaque")]
    Opaque {
        provider: ProviderKind,
        block: Value,
    },
    #[serde(rename = "image")]
    Image {
        #[serde(rename = "mediaType")]
        media_type: String,
        data: String,
    },
}

impl Serialize for ContentPart {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        let wire = match self.clone() {
            Self::Text(value) => WirePart::Text { value },
            Self::ToolCall(value) => WirePart::ToolCall { value },
            Self::ToolResult(value) => WirePart::ToolResult { value },
            Self::Opaque { provider, block } => WirePart::Opaque { provider, block },
            Self::Image { media_type, data } => WirePart::Image {
                media_type,
                data: base64::encode(&data),
            },
        };
        wire.serialize(s)
    }
}

impl<'de> Deserialize<'de> for ContentPart {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        Ok(match WirePart::deserialize(d)? {
            WirePart::Text { value } => Self::Text(value),
            WirePart::ToolCall { value } => Self::ToolCall(value),
            WirePart::ToolResult { value } => Self::ToolResult(value),
            WirePart::Opaque { provider, block } => Self::Opaque { provider, block },
            WirePart::Image { media_type, data } => Self::Image {
                media_type,
                data: base64::decode(&data)
                    .ok_or_else(|| serde::de::Error::custom("invalid base64 image data"))?,
            },
        })
    }
}

/// Swift writes `UUID` upper-case; either case reads.
pub(crate) mod uuid_upper {
    use serde::{Deserialize, Deserializer, Serializer};
    use uuid::Uuid;

    pub fn serialize<S: Serializer>(id: &Uuid, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&id.hyphenated().to_string().to_uppercase())
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Uuid, D::Error> {
        let text = String::deserialize(d)?;
        Uuid::parse_str(&text).map_err(serde::de::Error::custom)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ChatMessage {
    #[serde(with = "uuid_upper")]
    pub id: Uuid,
    pub role: ChatRole,
    pub parts: Vec<ContentPart>,
}

impl ChatMessage {
    pub fn new(role: ChatRole, parts: Vec<ContentPart>) -> Self {
        Self {
            id: Uuid::new_v4(),
            role,
            parts,
        }
    }

    pub fn user(text: impl Into<String>) -> Self {
        Self::new(ChatRole::User, vec![ContentPart::Text(text.into())])
    }

    /// The text parts joined.
    pub fn text(&self) -> String {
        self.parts
            .iter()
            .filter_map(|p| match p {
                ContentPart::Text(t) => Some(t.as_str()),
                _ => None,
            })
            .collect()
    }

    pub fn tool_calls(&self) -> Vec<ToolCall> {
        self.parts
            .iter()
            .filter_map(|p| match p {
                ContentPart::ToolCall(c) => Some(c.clone()),
                _ => None,
            })
            .collect()
    }

    pub fn images(&self) -> Vec<(&str, &[u8])> {
        self.parts
            .iter()
            .filter_map(|p| match p {
                ContentPart::Image { media_type, data } => {
                    Some((media_type.as_str(), data.as_slice()))
                }
                _ => None,
            })
            .collect()
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct ToolDefinition {
    pub name: String,
    pub description: String,
    pub input_schema: Value,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct TokenUsage {
    pub input_tokens: i64,
    pub output_tokens: i64,
}

impl std::ops::Add for TokenUsage {
    type Output = Self;
    fn add(self, b: Self) -> Self {
        Self {
            input_tokens: self.input_tokens + b.input_tokens,
            output_tokens: self.output_tokens + b.output_tokens,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StopReason {
    EndTurn,
    ToolUse,
    MaxTokens,
    Refusal,
    Other(String),
}

impl StopReason {
    pub fn from_anthropic(raw: Option<&str>) -> Self {
        match raw {
            None | Some("end_turn") | Some("stop_sequence") => Self::EndTurn,
            Some("tool_use") => Self::ToolUse,
            Some("max_tokens") => Self::MaxTokens,
            Some("refusal") => Self::Refusal,
            Some(other) => Self::Other(other.to_string()),
        }
    }
}

#[derive(Debug, Clone)]
pub struct ModelRequest {
    pub model: String,
    pub system: Option<String>,
    pub messages: Vec<ChatMessage>,
    pub tools: Vec<ToolDefinition>,
    pub max_tokens: u32,
    /// Anthropic `output_config.effort`; ignored by providers without it.
    pub effort: Option<String>,
}

impl ModelRequest {
    pub const DEFAULT_MAX_TOKENS: u32 = 32_000;

    pub fn new(model: impl Into<String>, messages: Vec<ChatMessage>) -> Self {
        Self {
            model: model.into(),
            system: None,
            messages,
            tools: Vec::new(),
            max_tokens: Self::DEFAULT_MAX_TOKENS,
            effort: None,
        }
    }
}

/// Events of one model turn. A turn always ends with `Completed`, which
/// carries the assembled assistant message (in block order) for the history.
#[derive(Debug, Clone, PartialEq)]
pub enum StreamEvent {
    TextDelta(String),
    ThinkingDelta(String),
    ToolCallStarted {
        name: String,
    },
    /// A fragment of a tool call's JSON arguments as they stream (Anthropic).
    ToolInputDelta {
        call_id: String,
        name: String,
        fragment: String,
    },
    Completed {
        message: ChatMessage,
        stop_reason: StopReason,
        usage: TokenUsage,
        served_by: Option<String>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModelInfo {
    pub id: String,
    pub display_name: String,
    pub supports_tools: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ProviderError {
    #[error("No API key for {}. Add one in Settings.", .0.display_name())]
    MissingApiKey(ProviderKind),
    #[error("Invalid base URL: {0}")]
    InvalidBaseUrl(String),
    #[error("HTTP {status}: {message}")]
    Http { status: u16, message: String },
    #[error("{error_type}: {message}")]
    Api { error_type: String, message: String },
    #[error("{0}")]
    Unreachable(String),
    #[error("Unexpected response: {0}")]
    MalformedResponse(String),
}
