//! App settings and presets (SnazzyCore/AppSettings.swift, Presets.swift). The
//! same field names, and the same tolerant reading: every field may be missing
//! and falls back to its default, so settings and presets from any version (and
//! from `.snazzy` files) load everywhere. Spec: docs/specs/settings.md.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::iso8601::Date;
use crate::json;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ProviderKind {
    /// Apple's on-device model: Mac only. Read, kept, never run here.
    #[serde(rename = "appleOnDevice")]
    AppleOnDevice,
    #[serde(rename = "anthropic")]
    Anthropic,
    #[serde(rename = "ollama")]
    Ollama,
}

impl ProviderKind {
    pub fn display_name(self) -> &'static str {
        match self {
            ProviderKind::AppleOnDevice => "Apple Intelligence (on-device)",
            ProviderKind::Anthropic => "Anthropic",
            ProviderKind::Ollama => "Ollama (local)",
        }
    }

    /// Never sends anything off this computer by its nature (Ollama can still
    /// point at another computer: use `AppSettings::runs_on_this_computer`).
    pub fn is_local(self) -> bool {
        !matches!(self, ProviderKind::Anthropic)
    }

    /// Credential-store account for providers that need an API key.
    pub fn keychain_account(self) -> Option<&'static str> {
        matches!(self, ProviderKind::Anthropic).then_some("anthropic")
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum AssistantTask {
    #[serde(rename = "planning")]
    Planning,
    #[serde(rename = "writing")]
    Writing,
    #[serde(rename = "building")]
    Building,
    #[serde(rename = "quickCommands")]
    QuickCommands,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ModelSelection {
    pub provider: ProviderKind,
    pub model: String,
}

impl ModelSelection {
    pub fn new(provider: ProviderKind, model: &str) -> Self {
        Self {
            provider,
            model: model.into(),
        }
    }
}

/// Non-secret settings. Keys never live here.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(from = "RawAppSettings")]
pub struct AppSettings {
    pub planning: ModelSelection,
    pub writing: ModelSelection,
    /// The builder agent (prototypes and HTML decks).
    pub building: ModelSelection,
    #[serde(rename = "quickCommands")]
    pub quick_commands: ModelSelection,
    /// The task the chat currently runs as.
    #[serde(rename = "activeTask")]
    pub active_task: AssistantTask,
    #[serde(rename = "anthropicBaseURL")]
    pub anthropic_base_url: String,
    /// `output_config.effort`: low, medium, high, xhigh, max.
    #[serde(rename = "anthropicEffort")]
    pub anthropic_effort: String,
    #[serde(rename = "ollamaBaseURL")]
    pub ollama_base_url: String,
    #[serde(rename = "maxOutputTokens")]
    pub max_output_tokens: i64,
    #[serde(rename = "voiceAutoSend")]
    pub voice_auto_send: bool,
    #[serde(rename = "recordSessions")]
    pub record_sessions: bool,
    /// Chat text size in points, 11…24.
    #[serde(rename = "chatTextSize")]
    pub chat_text_size: f64,
    #[serde(rename = "speakReplies")]
    pub speak_replies: bool,
    #[serde(rename = "wakeWord")]
    pub wake_word: String,
    #[serde(rename = "alwaysNeedWakeWord")]
    pub always_need_wake_word: bool,
    #[serde(rename = "voiceIdentifier")]
    pub voice_identifier: String,
    /// 0.1…0.9 (0.5 is normal).
    #[serde(rename = "speechRate")]
    pub speech_rate: f64,
    /// Cloud providers the user has agreed to send content to.
    #[serde(rename = "cloudConsent")]
    pub cloud_consent: Vec<String>,
}

impl Default for AppSettings {
    fn default() -> Self {
        let opus = ModelSelection::new(ProviderKind::Anthropic, "claude-opus-5-5");
        Self {
            planning: opus.clone(),
            writing: opus.clone(),
            building: opus,
            quick_commands: ModelSelection::new(ProviderKind::Anthropic, "claude-sonnet-5-5"),
            active_task: AssistantTask::Planning,
            anthropic_base_url: "https://api.anthropic.com".into(),
            anthropic_effort: "medium".into(),
            ollama_base_url: "http://localhost:11434".into(),
            max_output_tokens: 32_000,
            voice_auto_send: false,
            record_sessions: true,
            chat_text_size: 14.0,
            speak_replies: true,
            wake_word: "Snazzy".into(),
            always_need_wake_word: false,
            voice_identifier: String::new(),
            speech_rate: 0.5,
            cloud_consent: vec![],
        }
    }
}

/// Every field optional (missing or null = default); a field of the wrong type
/// still fails, as on the Mac.
#[derive(Deserialize)]
struct RawAppSettings {
    planning: Option<ModelSelection>,
    writing: Option<ModelSelection>,
    building: Option<ModelSelection>,
    #[serde(rename = "quickCommands")]
    quick_commands: Option<ModelSelection>,
    #[serde(rename = "activeTask")]
    active_task: Option<AssistantTask>,
    #[serde(rename = "anthropicBaseURL")]
    anthropic_base_url: Option<String>,
    #[serde(rename = "anthropicEffort")]
    anthropic_effort: Option<String>,
    #[serde(rename = "ollamaBaseURL")]
    ollama_base_url: Option<String>,
    #[serde(rename = "maxOutputTokens")]
    max_output_tokens: Option<i64>,
    #[serde(rename = "voiceAutoSend")]
    voice_auto_send: Option<bool>,
    #[serde(rename = "recordSessions")]
    record_sessions: Option<bool>,
    #[serde(rename = "chatTextSize")]
    chat_text_size: Option<f64>,
    #[serde(rename = "speakReplies")]
    speak_replies: Option<bool>,
    #[serde(rename = "wakeWord")]
    wake_word: Option<String>,
    #[serde(rename = "alwaysNeedWakeWord")]
    always_need_wake_word: Option<bool>,
    #[serde(rename = "voiceIdentifier")]
    voice_identifier: Option<String>,
    #[serde(rename = "speechRate")]
    speech_rate: Option<f64>,
    #[serde(rename = "cloudConsent")]
    cloud_consent: Option<Vec<String>>,
}

impl From<RawAppSettings> for AppSettings {
    fn from(r: RawAppSettings) -> Self {
        let d = AppSettings::default();
        AppSettings {
            planning: r.planning.unwrap_or(d.planning),
            writing: r.writing.unwrap_or(d.writing),
            building: r.building.unwrap_or(d.building),
            quick_commands: r.quick_commands.unwrap_or(d.quick_commands),
            active_task: r.active_task.unwrap_or(d.active_task),
            anthropic_base_url: r.anthropic_base_url.unwrap_or(d.anthropic_base_url),
            anthropic_effort: r.anthropic_effort.unwrap_or(d.anthropic_effort),
            ollama_base_url: r.ollama_base_url.unwrap_or(d.ollama_base_url),
            max_output_tokens: r.max_output_tokens.unwrap_or(d.max_output_tokens),
            voice_auto_send: r.voice_auto_send.unwrap_or(d.voice_auto_send),
            record_sessions: r.record_sessions.unwrap_or(d.record_sessions),
            chat_text_size: r
                .chat_text_size
                .unwrap_or(d.chat_text_size)
                .clamp(11.0, 24.0),
            speak_replies: r.speak_replies.unwrap_or(d.speak_replies),
            wake_word: r.wake_word.unwrap_or(d.wake_word),
            always_need_wake_word: r.always_need_wake_word.unwrap_or(d.always_need_wake_word),
            voice_identifier: r.voice_identifier.unwrap_or(d.voice_identifier),
            speech_rate: r.speech_rate.unwrap_or(d.speech_rate).clamp(0.1, 0.9),
            cloud_consent: r.cloud_consent.unwrap_or_default(),
        }
    }
}

impl AppSettings {
    pub fn selection(&self, task: AssistantTask) -> &ModelSelection {
        match task {
            AssistantTask::Planning => &self.planning,
            AssistantTask::Writing => &self.writing,
            AssistantTask::Building => &self.building,
            AssistantTask::QuickCommands => &self.quick_commands,
        }
    }

    pub fn set_selection(&mut self, selection: ModelSelection, task: AssistantTask) {
        match task {
            AssistantTask::Planning => self.planning = selection,
            AssistantTask::Writing => self.writing = selection,
            AssistantTask::Building => self.building = selection,
            AssistantTask::QuickCommands => self.quick_commands = selection,
        }
    }

    /// Whether `kind`'s model runs on this computer. Ollama can point at another
    /// one; then what's sent leaves this computer. (`runsOnThisMac` on the Mac.)
    pub fn runs_on_this_computer(&self, kind: ProviderKind) -> bool {
        if kind != ProviderKind::Ollama {
            return kind.is_local();
        }
        let host = url_host(&self.ollama_base_url)
            .unwrap_or_default()
            .to_lowercase();
        ["localhost", "127.0.0.1", "::1"].contains(&host.as_str())
    }

    /// Who receives what's sent to `kind`, for "Send … to X?" prompts.
    pub fn recipient_name(&self, kind: ProviderKind) -> String {
        if kind != ProviderKind::Ollama || self.runs_on_this_computer(kind) {
            return kind.display_name().into();
        }
        format!(
            "Ollama at {}",
            url_host(&self.ollama_base_url).unwrap_or_else(|| self.ollama_base_url.clone())
        )
    }

    pub fn to_json(&self) -> String {
        json::to_string(self, json::Style::COMPACT).unwrap_or_default()
    }
}

/// The host of an absolute URL like `URL(string:)?.host()`: None when it isn't a
/// URL (spaces, no scheme), IPv6 without brackets.
pub fn url_host(url: &str) -> Option<String> {
    if url.is_empty() || url.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return None;
    }
    let (_, rest) = url.split_once("://")?;
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    let host_port = authority.rsplit_once('@').map_or(authority, |(_, h)| h);
    if let Some(v6) = host_port.strip_prefix('[') {
        return v6.split_once(']').map(|(h, _)| h.to_string());
    }
    Some(host_port.split(':').next().unwrap_or("").to_string())
}

/// A named snapshot of settings (SnazzyCore/Presets.swift). `capture` (devices,
/// layout, per-device crop) is kept as JSON so presets round-trip unchanged.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SettingsPreset {
    pub name: String,
    pub notes: String,
    pub created: Date,
    pub updated: Date,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub capture: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub app: Option<AppSettings>,
}

impl SettingsPreset {
    /// As `PresetStore` saves it: pretty, sorted keys, ISO dates.
    pub fn to_json(&self) -> String {
        json::to_string(self, json::Style::PRETTY).unwrap_or_default()
    }
}

/// File-safe name: two names with the same file name are the same preset.
pub fn preset_file_name(name: &str) -> String {
    let cleaned: String = name
        .to_lowercase()
        .chars()
        .map(|c| {
            if c.is_alphabetic() || c.is_numeric() {
                c
            } else {
                '-'
            }
        })
        .collect();
    let slug = cleaned
        .split('-')
        .filter(|p| !p.is_empty())
        .collect::<Vec<_>>()
        .join("-");
    (if slug.is_empty() {
        "preset".to_string()
    } else {
        slug.chars().take(80).collect()
    }) + ".json"
}
