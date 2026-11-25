//! Voice notes (docs/specs/voice-notes.md): the window records with the
//! webview's MediaRecorder and hands the audio here to keep. The words come from
//! a transcription server the user runs (whisper.cpp, or any OpenAI-style
//! `/v1/audio/transcriptions`): audio goes nowhere else, and to a server on
//! another computer only once the user says it's theirs.

use std::path::PathBuf;
use std::sync::Mutex;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use snazzy_core::b64;
use snazzy_core::iso8601::Date;
use snazzy_core::voice_notes::{
    self, Mark, VoiceNote, VoiceNoteStore, parse_transcription, transcript_from,
    transcription_request,
};
use tauri::State;

const NO_HOME: &str = "Can't find your home folder, so there's nowhere to keep voice notes.";

/// Where the words come from (saved as JSON in the data folder).
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(default, rename_all = "camelCase")]
pub struct VoiceSettings {
    /// e.g. `http://localhost:8080` (whisper.cpp's server) or an OpenAI-style base URL. Empty: audio only.
    pub server: String,
    /// The model name some servers want (`whisper-1`, `base.en`…).
    pub model: String,
    /// The user said the server (on another computer) is theirs, so audio may go there.
    pub remote_ok: bool,
}

impl VoiceSettings {
    fn on_this_computer(&self) -> bool {
        let rest = self
            .server
            .trim()
            .trim_start_matches("http://")
            .trim_start_matches("https://");
        let host = rest.split(['/', '?']).next().unwrap_or("");
        let host = host.rsplit_once(':').map_or(host, |(h, p)| {
            if p.chars().all(|c| c.is_ascii_digit()) {
                h
            } else {
                host
            }
        });
        matches!(host, "localhost" | "127.0.0.1" | "[::1]" | "::1")
    }
}

pub struct VoiceState {
    store: Option<VoiceNoteStore>,
    settings_path: Option<PathBuf>,
    settings: Mutex<VoiceSettings>,
    downloads: Option<PathBuf>,
}

impl VoiceState {
    pub fn new() -> Self {
        let folders = snazzy_platform::paths::folders();
        let settings_path = folders.as_ref().map(|f| f.data.join("voice-notes.json"));
        let settings = settings_path
            .as_ref()
            .and_then(|p| std::fs::read(p).ok())
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        Self {
            store: folders
                .as_ref()
                .map(|f| VoiceNoteStore::new(voice_notes::folder_in(&f.data))),
            settings_path,
            settings: Mutex::new(settings),
            downloads: folders.map(|f| f.downloads),
        }
    }

    fn store(&self) -> Result<&VoiceNoteStore, String> {
        self.store.as_ref().ok_or_else(|| NO_HOME.to_string())
    }

    fn settings(&self) -> VoiceSettings {
        self.settings.lock().map(|s| s.clone()).unwrap_or_default()
    }
}

fn device() -> &'static str {
    if cfg!(windows) { "Windows" } else { "Linux" }
}

/// A note as the window shows it, with its shown title.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NoteView {
    #[serde(flatten)]
    note: VoiceNote,
    display_title: String,
    paragraphs: Vec<voice_notes::Segment>,
    edited: bool,
    markdown: String,
}

fn view(note: VoiceNote) -> NoteView {
    NoteView {
        display_title: note.display_title(),
        paragraphs: note.paragraphs(),
        edited: !note.segments.is_empty() && !note.transcript_matches_segments(),
        markdown: note.markdown(),
        note,
    }
}

#[tauri::command]
pub fn voice_notes(
    state: State<'_, VoiceState>,
    query: Option<String>,
) -> Result<Vec<NoteView>, String> {
    let q = query.unwrap_or_default();
    Ok(state
        .store()?
        .all()
        .into_iter()
        .filter(|n| n.matches(&q))
        .map(view)
        .collect())
}

#[tauri::command]
pub fn voice_note(state: State<'_, VoiceState>, id: String) -> Result<NoteView, String> {
    state
        .store()?
        .note(&id)
        .map(view)
        .ok_or_else(|| "That voice note isn't there any more.".to_string())
}

/// Keeps a recording: the audio (base64 from the window), its length and the marks.
#[tauri::command]
pub fn save_voice_recording(
    state: State<'_, VoiceState>,
    audio: String,
    mime: String,
    duration: f64,
    marks: Vec<f64>,
    language: Option<String>,
) -> Result<NoteView, String> {
    let store = state.store()?;
    let bytes = b64::decode(&audio).ok_or("The recording didn't arrive.")?;
    if bytes.is_empty() {
        return Err("Nothing was recorded. Check the microphone.".into());
    }
    let now = Date::now();
    let id = voice_notes::new_id();
    let mut note = VoiceNote::new(id, now, device());
    note.duration = duration.max(0.0);
    note.language = language.filter(|l| !l.trim().is_empty());
    note.marks = marks
        .into_iter()
        .map(|at| Mark {
            at,
            label: "Idea".into(),
        })
        .collect();
    store
        .put_audio(&mut note, &bytes, voice_notes::audio_extension(&mime))
        .map_err(|e| e.to_string())?;
    store.save(&mut note, now).map_err(|e| e.to_string())?;
    Ok(view(note))
}

/// Turns the note's audio into words with the user's transcription server.
#[tauri::command]
pub async fn transcribe_voice_note(
    state: State<'_, VoiceState>,
    id: String,
) -> Result<NoteView, String> {
    let settings = state.settings();
    if settings.server.trim().is_empty() {
        return Err(
            "Add a transcription server in Voice Notes › Settings to turn recordings into text."
                .into(),
        );
    }
    if !settings.on_this_computer() && !settings.remote_ok {
        return Err("That transcription server is on another computer. Tick “This server is mine” in Voice Notes › Settings to send recordings to it.".into());
    }
    let store = state.store()?.clone();
    let note = store
        .note(&id)
        .ok_or("That voice note isn't there any more.")?;
    let path = store
        .audio_path(&note)
        .ok_or("This note has no recording.")?;
    let audio = std::fs::read(&path).map_err(|e| e.to_string())?;
    let file_name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let boundary = format!("snazzy-{}", voice_notes::new_id());
    let request = transcription_request(
        &settings.server,
        &audio,
        &file_name,
        &settings.model,
        note.language.as_deref(),
        &boundary,
    )
    .map_err(|e| e.to_string())?;
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(30 * 60))
        .build()
        .map_err(|e| e.to_string())?;
    let response = client
        .post(&request.url)
        .header("Content-Type", request.content_type)
        .body(request.body)
        .send()
        .await
        .map_err(|e| format!("Couldn't reach the transcription server: {e}"))?;
    let status = response.status();
    let body = response.bytes().await.map_err(|e| e.to_string())?;
    let segments = match parse_transcription(&body, note.duration) {
        Ok(s) => s,
        Err(_) if !status.is_success() => {
            return Err(format!("The transcription server answered {status}."));
        }
        Err(e) => return Err(e.to_string()),
    };
    if segments.is_empty() {
        return Err("No speech was found in the recording.".into());
    }
    // Text edited by hand meanwhile wins.
    let mut current = store
        .note(&id)
        .ok_or("That voice note isn't there any more.")?;
    if current.transcript != note.transcript {
        return Ok(view(current));
    }
    current.transcript = transcript_from(&segments);
    current.segments = segments;
    current.transcribed_by = "whisper-server".into();
    store
        .save(&mut current, Date::now())
        .map_err(|e| e.to_string())?;
    Ok(view(current))
}

#[tauri::command]
pub fn update_voice_note(
    state: State<'_, VoiceState>,
    id: String,
    title: Option<String>,
    transcript: Option<String>,
    tags: Option<Vec<String>>,
) -> Result<NoteView, String> {
    let store = state.store()?;
    let mut note = store
        .note(&id)
        .ok_or("That voice note isn't there any more.")?;
    if let Some(t) = title {
        note.title = t.trim().to_string();
    }
    if let Some(t) = transcript.filter(|t| *t != note.transcript) {
        note.transcript = t;
        if note.transcribed_by == "none" {
            note.transcribed_by = "typed".into();
        }
    }
    if let Some(tags) = tags {
        note.tags = tags
            .into_iter()
            .map(|t| t.trim().to_string())
            .filter(|t| !t.is_empty())
            .collect();
    }
    store
        .save(&mut note, Date::now())
        .map_err(|e| e.to_string())?;
    Ok(view(note))
}

#[tauri::command]
pub fn delete_voice_note(state: State<'_, VoiceState>, id: String) -> Result<(), String> {
    state.store()?.delete(&id).map_err(|e| e.to_string())
}

/// The recording, for the window's player.
#[derive(Serialize)]
pub struct Audio {
    data: String,
    mime: String,
}

#[tauri::command]
pub fn voice_note_audio(state: State<'_, VoiceState>, id: String) -> Result<Audio, String> {
    let store = state.store()?;
    let note = store
        .note(&id)
        .ok_or("That voice note isn't there any more.")?;
    let path = store
        .audio_path(&note)
        .ok_or("This note has no recording.")?;
    let bytes = std::fs::read(&path).map_err(|e| e.to_string())?;
    let mime = match path.extension().and_then(|e| e.to_str()).unwrap_or("") {
        "ogg" => "audio/ogg",
        "wav" => "audio/wav",
        "m4a" => "audio/mp4",
        _ => "audio/webm",
    };
    Ok(Audio {
        data: b64::encode(&bytes),
        mime: mime.into(),
    })
}

/// Saves the note as Markdown in Downloads; returns the file's path.
#[tauri::command]
pub fn export_voice_note(state: State<'_, VoiceState>, id: String) -> Result<String, String> {
    let note = state
        .store()?
        .note(&id)
        .ok_or("That voice note isn't there any more.")?;
    let dir = state.downloads.clone().ok_or_else(|| NO_HOME.to_string())?;
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let name: String = note
        .display_title()
        .chars()
        .map(|c| if "/\\:*?\"<>|".contains(c) { '-' } else { c })
        .take(80)
        .collect();
    let mut path = dir.join(format!("{}.md", name.trim()));
    let mut n = 2;
    while path.exists() {
        path = dir.join(format!("{}-{n}.md", name.trim()));
        n += 1;
    }
    std::fs::write(&path, note.markdown()).map_err(|e| e.to_string())?;
    Ok(path.to_string_lossy().into_owned())
}

#[tauri::command]
pub fn show_voice_notes_folder(state: State<'_, VoiceState>) -> Result<(), String> {
    let root = state.store()?.root.clone();
    std::fs::create_dir_all(&root).map_err(|e| e.to_string())?;
    snazzy_platform::open::open_folder(&root)
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VoiceStatus {
    settings: VoiceSettings,
    /// The server is on this computer (audio stays here).
    local: bool,
}

#[tauri::command]
pub fn voice_settings(state: State<'_, VoiceState>) -> VoiceStatus {
    let settings = state.settings();
    VoiceStatus {
        local: settings.on_this_computer(),
        settings,
    }
}

#[tauri::command]
pub fn set_voice_settings(
    state: State<'_, VoiceState>,
    settings: VoiceSettings,
) -> Result<VoiceStatus, String> {
    let mut settings = settings;
    settings.server = settings.server.trim().to_string();
    if !settings.server.is_empty()
        && !settings.server.starts_with("http://")
        && !settings.server.starts_with("https://")
    {
        return Err("The server's address should start with http:// or https://.".into());
    }
    if let Some(path) = &state.settings_path {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        }
        let json = serde_json::to_vec_pretty(&settings).map_err(|e| e.to_string())?;
        let partial = path.with_extension("json.partial");
        std::fs::write(&partial, json).map_err(|e| e.to_string())?;
        std::fs::rename(&partial, path).map_err(|e| e.to_string())?;
    }
    if let Ok(mut s) = state.settings.lock() {
        *s = settings.clone();
    }
    Ok(VoiceStatus {
        local: settings.on_this_computer(),
        settings,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(server: &str) -> VoiceSettings {
        VoiceSettings {
            server: server.into(),
            ..Default::default()
        }
    }

    #[test]
    fn which_servers_are_on_this_computer() {
        assert!(s("http://localhost:8080").on_this_computer());
        assert!(s("http://127.0.0.1:8080/inference").on_this_computer());
        assert!(s("http://[::1]:9000").on_this_computer());
        assert!(!s("http://192.168.1.20:8080").on_this_computer());
        assert!(!s("https://api.example.com").on_this_computer());
        assert!(!s("http://localhost.example.com").on_this_computer());
    }

    #[test]
    fn ids_are_safe_and_distinct() {
        let a = voice_notes::new_id();
        assert_ne!(a, voice_notes::new_id());
        assert!(voice_notes::is_safe_id(&a), "{a}");
    }
}
