//! Chat: settings, keys, models, and sending a message with the reply streamed
//! to the window. Tools come in phase 4; for now the agent only talks.

use std::path::PathBuf;
use std::sync::Arc;

use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use snazzy_agent::{
    AnthropicProvider, ChatMessage, ConversationRunner, ModelProvider, OllamaProvider, RunnerEvent,
    ToolRegistry, runs_on_this_computer, types::ProviderKind,
};
use snazzy_platform::secrets::{CredentialStore, SecretStore};
use tauri::ipc::Channel;
use tokio::sync::Mutex;

const ANTHROPIC_ACCOUNT: &str = "anthropic";
const SYSTEM_PROMPT: &str = "You are Snazzy Pro's assistant on Windows and Linux. You help plan and write presentations. \
Answer in short, clear paragraphs. Tools for slides, recording and the live room arrive in later versions; \
if asked to do those, say what you would do and that it isn't available yet.";

/// What the user chose (saved as JSON in the data folder; no secrets here).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default, rename_all = "camelCase")]
pub struct ChatSettings {
    /// "ollama" or "anthropic".
    pub provider: String,
    pub model: String,
    pub ollama_url: String,
    /// The user agreed to send chats to a cloud provider.
    pub cloud_consent: bool,
}

impl Default for ChatSettings {
    fn default() -> Self {
        Self {
            provider: "ollama".into(),
            model: String::new(),
            ollama_url: "http://localhost:11434".into(),
            cloud_consent: false,
        }
    }
}

impl ChatSettings {
    fn kind(&self) -> ProviderKind {
        if self.provider == "anthropic" {
            ProviderKind::Anthropic
        } else {
            ProviderKind::Ollama
        }
    }
}

/// What the window shows about the current choice.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatStatus {
    settings: ChatSettings,
    has_anthropic_key: bool,
    /// Messages stay on this computer.
    local: bool,
}

/// Events streamed to the window while a reply is written.
#[derive(Clone, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum ChatEvent {
    Text { delta: String },
    Thinking,
    Tool { name: String },
    Usage { input: i64, output: i64 },
    NeedsUser { message: String },
    Done,
    Error { message: String },
}

pub struct ChatState {
    settings_path: Option<PathBuf>,
    settings: Mutex<ChatSettings>,
    history: Mutex<Vec<ChatMessage>>,
    running: Mutex<Option<tokio::task::AbortHandle>>,
    secrets: Arc<dyn SecretStore>,
}

impl ChatState {
    pub fn new() -> Self {
        let settings_path =
            snazzy_platform::paths::folders().map(|f| f.data.join("desktop-chat.json"));
        let settings = settings_path
            .as_ref()
            .and_then(|p| std::fs::read(p).ok())
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        Self {
            settings_path,
            settings: Mutex::new(settings),
            history: Mutex::new(Vec::new()),
            running: Mutex::new(None),
            secrets: Arc::new(CredentialStore::new()),
        }
    }

    async fn status(&self) -> ChatStatus {
        let settings = self.settings.lock().await.clone();
        let has_anthropic_key = matches!(self.secrets.get(ANTHROPIC_ACCOUNT), Ok(Some(_)));
        let local = runs_on_this_computer(settings.kind(), &settings.ollama_url);
        ChatStatus {
            settings,
            has_anthropic_key,
            local,
        }
    }

    fn save(&self, settings: &ChatSettings) -> Result<(), String> {
        let Some(path) = &self.settings_path else {
            return Ok(());
        };
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        }
        let json = serde_json::to_vec_pretty(settings).map_err(|e| e.to_string())?;
        let partial = path.with_extension("json.partial");
        std::fs::write(&partial, json).map_err(|e| e.to_string())?;
        std::fs::rename(&partial, path).map_err(|e| e.to_string())
    }

    fn provider(&self, settings: &ChatSettings) -> Result<Arc<dyn ModelProvider>, String> {
        match settings.kind() {
            ProviderKind::Anthropic => {
                let key = self
                    .secrets
                    .get(ANTHROPIC_ACCOUNT)
                    .map_err(|e| e.to_string())?
                    .ok_or("Add your Anthropic API key in Settings first.")?;
                Ok(Arc::new(
                    AnthropicProvider::new(key).map_err(|e| e.to_string())?,
                ))
            }
            _ => Ok(Arc::new(
                OllamaProvider::new(&settings.ollama_url).map_err(|e| e.to_string())?,
            )),
        }
    }
}

impl Default for ChatState {
    fn default() -> Self {
        Self::new()
    }
}

#[tauri::command]
pub async fn chat_status(state: tauri::State<'_, ChatState>) -> Result<ChatStatus, String> {
    Ok(state.status().await)
}

#[tauri::command]
pub async fn set_chat_settings(
    state: tauri::State<'_, ChatState>,
    settings: ChatSettings,
) -> Result<ChatStatus, String> {
    let mut current = state.settings.lock().await;
    // Consent is only given through `agree_to_cloud`.
    let consent = current.cloud_consent;
    *current = ChatSettings {
        cloud_consent: consent,
        ..settings
    };
    state.save(&current)?;
    drop(current);
    Ok(state.status().await)
}

#[tauri::command]
pub async fn agree_to_cloud(state: tauri::State<'_, ChatState>) -> Result<ChatStatus, String> {
    let mut current = state.settings.lock().await;
    current.cloud_consent = true;
    state.save(&current)?;
    drop(current);
    Ok(state.status().await)
}

/// Saves (or, when empty, removes) the Anthropic key in the OS credential store.
#[tauri::command]
pub async fn set_anthropic_key(
    state: tauri::State<'_, ChatState>,
    key: String,
) -> Result<ChatStatus, String> {
    state
        .secrets
        .set(ANTHROPIC_ACCOUNT, key.trim())
        .map_err(|e| e.to_string())?;
    Ok(state.status().await)
}

#[tauri::command]
pub async fn list_models(state: tauri::State<'_, ChatState>) -> Result<Vec<String>, String> {
    let settings = state.settings.lock().await.clone();
    let provider = state.provider(&settings)?;
    let models = provider.list_models().await.map_err(|e| e.to_string())?;
    Ok(models.into_iter().map(|m| m.id).collect())
}

#[tauri::command]
pub async fn new_conversation(state: tauri::State<'_, ChatState>) -> Result<(), String> {
    if let Some(handle) = state.running.lock().await.take() {
        handle.abort();
    }
    state.history.lock().await.clear();
    Ok(())
}

#[tauri::command]
pub async fn stop_chat(state: tauri::State<'_, ChatState>) -> Result<(), String> {
    if let Some(handle) = state.running.lock().await.take() {
        handle.abort();
    }
    Ok(())
}

/// Sends a message; the reply streams to `events`. Returns when the turn ends.
#[tauri::command]
pub async fn send_chat(
    state: tauri::State<'_, ChatState>,
    text: String,
    events: Channel<ChatEvent>,
) -> Result<(), String> {
    let settings = state.settings.lock().await.clone();
    let local = runs_on_this_computer(settings.kind(), &settings.ollama_url);
    if !local && !settings.cloud_consent {
        return Err("consent-needed".into());
    }
    if settings.model.trim().is_empty() {
        return Err("Choose a model in Settings first.".into());
    }
    let provider = state.provider(&settings)?;
    let runner = ConversationRunner::new(provider, ToolRegistry::new([]), settings.model.clone())
        .with_system(SYSTEM_PROMPT);

    let mut history = state.history.lock().await.clone();
    history.push(ChatMessage::user(text));
    *state.history.lock().await = history.clone();

    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<Result<RunnerEvent, String>>();
    let task = tokio::spawn(async move {
        let mut stream = runner.run(history);
        while let Some(item) = stream.next().await {
            if tx.send(item.map_err(|e| e.to_string())).is_err() {
                break;
            }
        }
    });
    *state.running.lock().await = Some(task.abort_handle());

    while let Some(item) = rx.recv().await {
        let event = match item {
            Ok(RunnerEvent::TextDelta(delta)) => ChatEvent::Text { delta },
            Ok(RunnerEvent::ThinkingDelta(_)) => ChatEvent::Thinking,
            Ok(RunnerEvent::ToolCallStarted { name }) => ChatEvent::Tool { name },
            Ok(RunnerEvent::Usage(u)) => ChatEvent::Usage {
                input: u.input_tokens,
                output: u.output_tokens,
            },
            Ok(RunnerEvent::NeedsUser(message)) => ChatEvent::NeedsUser { message },
            Ok(RunnerEvent::AssistantMessage { message, .. })
            | Ok(RunnerEvent::ToolResults(message)) => {
                // History is append-only (thinking blocks are echoed back untouched).
                state.history.lock().await.push(message);
                continue;
            }
            Ok(_) => continue,
            Err(message) => ChatEvent::Error { message },
        };
        let _ = events.send(event);
    }
    *state.running.lock().await = None;
    let _ = events.send(ChatEvent::Done);
    Ok(())
}
