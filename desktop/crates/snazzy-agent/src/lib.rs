//! The chat engine of Snazzy Pro for Windows and Linux.
//!
//! Behaviour follows the Mac app's `Assistant` module
//! (`Packages/SnazzyKit/Sources/Assistant`):
//! - [`ModelProvider`]s stream a turn and end with one `Completed` message:
//!   [`AnthropicProvider`] (SSE) and [`OllamaProvider`] (NDJSON).
//! - [`ToolRegistry`] validates calls against their JSON schemas and wraps
//!   results from outside the app as untrusted data.
//! - [`ConversationRunner`] is the tool loop: at most 12 rounds, and it stops
//!   to ask the user after two invalid rounds in a row.
//! - [`ChatMessage`] and [`Conversation`] serialize exactly as the Mac app's
//!   `Codable` types, so saved conversations are interchangeable.
//!
//! History sent to Anthropic is never edited or trimmed; thinking blocks are
//! echoed back as received. API keys come from the caller and are never logged.

pub mod anthropic;
mod base64;
pub mod conversation;
pub mod json;
pub mod ollama;
pub mod provider;
pub mod runner;
pub mod schema;
pub mod settings;
pub mod text_tool_calls;
pub mod tools;
pub mod types;

pub use anthropic::{AnthropicProvider, AnthropicStreamParser};
pub use conversation::{Conversation, ConversationStore, ConversationSummary};
pub use ollama::{OllamaProvider, OllamaStreamParser};
pub use provider::{EventStream, ModelProvider};
pub use runner::{ConfirmFn, ConversationRunner, RunnerEvent};
pub use settings::{recipient_name, runs_on_this_computer};
pub use tools::{
    RegisteredTool, ToolError, ToolHandler, ToolRegistry, is_read_only_name, untrusted,
};
pub use types::{
    ChatMessage, ChatRole, ContentPart, ModelInfo, ModelRequest, ProviderError, ProviderKind,
    StopReason, StreamEvent, TokenUsage, ToolCall, ToolDefinition, ToolResult,
};
