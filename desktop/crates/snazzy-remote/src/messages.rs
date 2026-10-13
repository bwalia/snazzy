//! Messages as Swift's synthesized `Codable` writes them: each enum case is an
//! object with one key, the case name, holding its associated values by label
//! (`_0`, `_1` for unlabelled ones; `{}` when there are none). Absent optionals
//! are left out. Keys are written sorted (any order is read).

use serde::{Deserialize, Serialize};
use snazzy_core::b64;

/// What the host is doing, sent to devices whenever it changes. Fields added
/// later must be optional, so older apps still decode it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct RemoteStatus {
    pub host_name: String,
    /// idle, countdown, recording, paused, finishing or failed
    pub recording: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub countdown: Option<i64>,
    pub elapsed: f64,
    pub mic_level: f64,
    /// What's being recorded, e.g. "Slides" or "Display: LG".
    pub source: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub deck_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub slide_index: Option<i64>,
    pub slide_count: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub slide_title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_slide_title: Option<String>,
    /// Speaker notes for the current slide (the teleprompter).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notes: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub live_room_viewers: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub broadcast: Option<String>,
    pub warnings: Vec<String>,
    /// The auto-scrolling teleprompter (None from hosts without one).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prompter: Option<PrompterState>,
}

impl RemoteStatus {
    pub fn idle(host_name: &str) -> Self {
        Self {
            host_name: host_name.into(),
            recording: "idle".into(),
            ..Self::default()
        }
    }

    pub fn is_recording(&self) -> bool {
        matches!(
            self.recording.as_str(),
            "recording" | "paused" | "countdown"
        )
    }
}

/// The camera prompter: devices show the same position (a fraction of the text)
/// and keep it moving between status updates.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrompterState {
    pub running: bool,
    /// Reading speed in words per minute (60…260, steps of 20).
    pub words_per_minute: f64,
    /// How far through the text, 0…1, when the status was made.
    pub progress: f64,
    /// The script, when it shows one instead of the slide's notes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub script: Option<String>,
    pub visible: bool,
}

impl PrompterState {
    pub const MIN_SPEED: f64 = 60.0;
    pub const MAX_SPEED: f64 = 260.0;
    pub const STEP: f64 = 20.0;

    pub fn words(text: Option<&str>) -> usize {
        text.unwrap_or("").split_whitespace().count()
    }

    /// The position `seconds` later, for notes of `words` words.
    pub fn progress_after(&self, seconds: f64, words: usize) -> f64 {
        if !self.running || words == 0 || seconds <= 0.0 {
            return self.progress;
        }
        (self.progress + seconds * self.words_per_minute / 60.0 / words as f64).min(1.0)
    }
}

impl Default for PrompterState {
    fn default() -> Self {
        Self {
            running: false,
            words_per_minute: 140.0,
            progress: 0.0,
            script: None,
            visible: true,
        }
    }
}

/// What a device can ask the host to do.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum RemoteCommand {
    #[serde(rename = "startRecording")]
    StartRecording {},
    #[serde(rename = "pauseRecording")]
    PauseRecording {},
    #[serde(rename = "resumeRecording")]
    ResumeRecording {},
    #[serde(rename = "stopRecording")]
    StopRecording {},
    #[serde(rename = "nextSlide")]
    NextSlide {},
    #[serde(rename = "previousSlide")]
    PreviousSlide {},
    #[serde(rename = "goToSlide")]
    GoToSlide {
        #[serde(rename = "_0")]
        index: i64,
    },
    #[serde(rename = "openPresentWindow")]
    OpenPresentWindow {},
    /// A message to the assistant, as if typed in the host's chat.
    #[serde(rename = "chat")]
    Chat {
        #[serde(rename = "_0")]
        text: String,
    },
    #[serde(rename = "prompter")]
    Prompter {
        #[serde(rename = "_0")]
        action: PrompterAction,
    },
    /// Checks the link is alive (answers ok, does nothing).
    #[serde(rename = "ping")]
    Ping {},
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum PrompterAction {
    #[serde(rename = "play")]
    Play {},
    #[serde(rename = "pause")]
    Pause {},
    #[serde(rename = "toggle")]
    Toggle {},
    #[serde(rename = "faster")]
    Faster {},
    #[serde(rename = "slower")]
    Slower {},
    /// Back to the top of the current slide's notes.
    #[serde(rename = "restart")]
    Restart {},
    /// Jumps to a position, 0…1.
    #[serde(rename = "seek")]
    Seek {
        #[serde(rename = "_0")]
        position: f64,
    },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum RemoteMessage {
    /// Device → host, first on every connection. `proof` is `security::proof` with
    /// the pairing secret (pairing) or the device's own key; missing only from old
    /// apps, which are told to update.
    #[serde(rename = "hello")]
    Hello {
        #[serde(rename = "deviceID")]
        device_id: String,
        #[serde(rename = "deviceName")]
        device_name: String,
        version: i64,
        pairing: bool,
        #[serde(
            default,
            skip_serializing_if = "Option::is_none",
            with = "b64::serde_opt_bytes"
        )]
        proof: Option<Vec<u8>>,
    },
    /// Host → device after pairing: the device's own key for future connections.
    #[serde(rename = "paired")]
    Paired {
        #[serde(rename = "hostID")]
        host_id: String,
        #[serde(rename = "hostName")]
        host_name: String,
        #[serde(rename = "deviceKey", with = "b64::serde_bytes")]
        device_key: Vec<u8>,
    },
    /// Host → device on a normal connection.
    #[serde(rename = "welcome")]
    Welcome {
        #[serde(rename = "hostID")]
        host_id: String,
        #[serde(rename = "hostName")]
        host_name: String,
    },
    #[serde(rename = "status")]
    Status {
        #[serde(rename = "_0")]
        status: Box<RemoteStatus>,
    },
    #[serde(rename = "command")]
    Command {
        id: i64,
        #[serde(rename = "_1")]
        command: RemoteCommand,
    },
    #[serde(rename = "result")]
    Result {
        id: i64,
        ok: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
    /// The assistant's reply to a chat command (final text).
    #[serde(rename = "chatReply")]
    ChatReply {
        #[serde(rename = "_0")]
        text: String,
    },
    /// Closing, with a reason.
    #[serde(rename = "bye")]
    Bye {
        #[serde(rename = "_0")]
        reason: String,
    },
}

/// Commands the watch may send through the iPhone (not chat: its replies have
/// nowhere to go; not the Present window).
pub fn watch_allows(command: &RemoteCommand) -> bool {
    !matches!(
        command,
        RemoteCommand::OpenPresentWindow {} | RemoteCommand::Chat { .. }
    )
}
