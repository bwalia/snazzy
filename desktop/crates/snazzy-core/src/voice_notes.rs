//! Voice notes (docs/specs/voice-notes.md): something said out loud, kept as
//! audio plus the words. The Mac's `SnazzyCore/VoiceNotes.swift` is the source
//! of truth; `note.json` here is written byte for byte as the Mac writes it.
//!
//! Windows and Linux have no on-device speech recognition the app can use, so
//! the words come from a transcription server the user runs themselves
//! (whisper.cpp's server, or anything with an OpenAI-style
//! `/v1/audio/transcriptions`): see [`transcription_request`].

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::WorkspaceError;
use crate::fold::fold;
use crate::iso8601::Date;
use crate::json::{self, Style};

pub const FORMAT: &str = "snazzy-voice-note";
pub const FILE_NAME: &str = "note.json";

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Segment {
    pub start: f64,
    pub end: f64,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Mark {
    pub at: f64,
    #[serde(default = "idea")]
    pub label: String,
}

fn idea() -> String {
    "Idea".into()
}

fn none() -> String {
    "none".into()
}

fn one() -> i64 {
    1
}

fn format_name() -> String {
    FORMAT.into()
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct VoiceNote {
    #[serde(default = "format_name")]
    pub format: String,
    #[serde(default = "one")]
    pub version: i64,
    pub id: String,
    #[serde(default)]
    pub title: String,
    #[serde(default = "epoch")]
    pub created_at: Date,
    /// Missing means `created_at` (filled in by [`VoiceNote::parse`]).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<Date>,
    #[serde(default)]
    pub duration: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub audio: Option<String>,
    #[serde(default)]
    pub transcript: String,
    #[serde(default)]
    pub segments: Vec<Segment>,
    #[serde(default)]
    pub marks: Vec<Mark>,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub device: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub language: Option<String>,
    #[serde(default = "none")]
    pub transcribed_by: String,
}

fn epoch() -> Date {
    Date::from_unix(0).expect("the epoch is a date")
}

impl VoiceNote {
    /// A new note, made now, on this device (`Windows` or `Linux`).
    pub fn new(id: impl Into<String>, created: Date, device: impl Into<String>) -> Self {
        Self {
            format: FORMAT.into(),
            version: 1,
            id: id.into(),
            title: String::new(),
            created_at: created,
            updated_at: Some(created),
            duration: 0.0,
            audio: None,
            transcript: String::new(),
            segments: Vec::new(),
            marks: Vec::new(),
            tags: Vec::new(),
            device: device.into(),
            language: None,
            transcribed_by: "none".into(),
        }
    }

    pub fn parse(data: &[u8]) -> Result<Self, WorkspaceError> {
        let mut note: VoiceNote = serde_json::from_slice(data)
            .map_err(|_| WorkspaceError::new("This isn't a Snazzy voice note."))?;
        if note.format != FORMAT {
            return Err(WorkspaceError::new("This isn't a Snazzy voice note."));
        }
        if note.version > 1 {
            return Err(WorkspaceError::new(
                "This voice note needs a newer Snazzy Pro.",
            ));
        }
        note.updated_at.get_or_insert(note.created_at);
        Ok(note)
    }

    /// `note.json` as the Mac writes it (pretty, sorted keys).
    pub fn to_json(&self) -> String {
        json::to_string(self, Style::PRETTY).unwrap_or_default()
    }

    /// The title given, else the first words said, else the date.
    pub fn display_title(&self) -> String {
        let given = self.title.trim();
        if !given.is_empty() {
            return given.to_string();
        }
        let derived = title_from(&self.transcript);
        if !derived.is_empty() {
            return derived;
        }
        format!("Voice note, {}", long_date(&self.created_at))
    }

    /// Every word of the query in the title, text or tags (case and accents ignored).
    pub fn matches(&self, query: &str) -> bool {
        let words: Vec<String> = query.split_whitespace().map(fold).collect();
        if words.is_empty() {
            return true;
        }
        let haystack = fold(&format!(
            "{} {} {}",
            self.display_title(),
            self.transcript,
            self.tags.join(" ")
        ));
        words.iter().all(|w| haystack.contains(w.as_str()))
    }

    /// The transcript hasn't been edited by hand since the segments were made.
    pub fn transcript_matches_segments(&self) -> bool {
        transcript_from(&self.segments) == self.transcript
    }

    /// Segments joined while the gap is under 2 s and the paragraph under 60 s.
    pub fn paragraphs(&self) -> Vec<Segment> {
        let mut out: Vec<Segment> = Vec::new();
        for s in &self.segments {
            let text = s.text.trim();
            if text.is_empty() {
                continue;
            }
            match out.last_mut() {
                Some(last) if s.start - last.end < 2.0 && s.end - last.start <= 60.0 => {
                    last.end = s.end;
                    last.text.push(' ');
                    last.text.push_str(text);
                }
                _ => out.push(Segment {
                    start: s.start,
                    end: s.end,
                    text: text.to_string(),
                }),
            }
        }
        out
    }

    /// The note as Markdown (copy/export), as the Mac makes it.
    pub fn markdown(&self) -> String {
        let mut out = format!("# {}\n\n", self.display_title());
        out.push('_');
        out.push_str(&long_date(&self.created_at));
        if self.duration > 0.0 {
            out.push_str(&format!(" · {}", clock(self.duration)));
        }
        out.push_str("_\n");
        if !self.tags.is_empty() {
            out.push_str(&format!("\nTags: {}\n", self.tags.join(", ")));
        }
        if !self.marks.is_empty() {
            out.push_str("\n## Marked\n\n");
            let mut marks = self.marks.clone();
            marks.sort_by(|a, b| a.at.total_cmp(&b.at));
            for m in marks {
                let said = self
                    .segments
                    .iter()
                    .rev()
                    .find(|s| s.start <= m.at + 0.5)
                    .map(|s| s.text.trim().to_string())
                    .unwrap_or_default();
                out.push_str(&format!("- {} {}", clock(m.at), m.label));
                if !said.is_empty() {
                    out.push_str(&format!(": “{said}”"));
                }
                out.push('\n');
            }
        }
        out.push_str("\n## Notes\n\n");
        if self.segments.is_empty() || !self.transcript_matches_segments() {
            if self.transcript.is_empty() {
                out.push_str("_(no words yet)_\n");
            } else {
                out.push_str(&self.transcript);
                out.push('\n');
            }
        } else {
            for p in self.paragraphs() {
                out.push_str(&format!("**{}** {}\n\n", clock(p.start), p.text));
            }
        }
        format!("{}\n", out.trim_matches('\n'))
    }
}

/// A short title from the first sentence: up to 7 words, outer punctuation
/// trimmed, first letter upper-cased.
pub fn title_from(text: &str) -> String {
    let first = text
        .split(['.', '!', '?', '\n'])
        .find(|s| !s.is_empty())
        .unwrap_or("");
    let words: Vec<&str> = first.split_whitespace().take(7).collect();
    if words.is_empty() {
        return String::new();
    }
    let joined = words.join(" ");
    let trimmed =
        joined.trim_matches(|c: char| c.is_ascii_punctuation() || is_unicode_punctuation(c));
    let mut chars = trimmed.chars();
    match chars.next() {
        Some(c) => c.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

fn is_unicode_punctuation(c: char) -> bool {
    matches!(
        c,
        '“' | '”' | '‘' | '’' | '«' | '»' | '…' | '–' | '—' | '¡' | '¿'
    )
}

/// The whole text from the segments.
pub fn transcript_from(segments: &[Segment]) -> String {
    segments
        .iter()
        .map(|s| s.text.trim())
        .filter(|t| !t.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

/// `m:ss` or `h:mm:ss`.
pub fn clock(seconds: f64) -> String {
    let s = seconds.max(0.0).floor() as u64;
    if s >= 3600 {
        format!("{}:{:02}:{:02}", s / 3600, s / 60 % 60, s % 60)
    } else {
        format!("{}:{:02}", s / 60, s % 60)
    }
}

fn long_date(d: &Date) -> String {
    let t = d.0;
    format!(
        "{} {} {}, {:02}:{:02} UTC",
        t.day(),
        t.month(),
        t.year(),
        t.hour(),
        t.minute()
    )
}

/// A new note's id: a lower-case UUID, as the Mac makes them.
pub fn new_id() -> String {
    uuid::Uuid::new_v4().to_string()
}

/// Ids: 1–64 ASCII letters, digits, `-` or `_`.
pub fn is_safe_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 64
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

fn is_safe_file_name(name: &str) -> bool {
    !name.is_empty() && !name.contains('/') && !name.contains('\\') && !name.starts_with('.')
}

/// Audio file extensions a note may keep.
pub fn audio_extension(mime: &str) -> &'static str {
    let m = mime.to_ascii_lowercase();
    if m.contains("webm") {
        "webm"
    } else if m.contains("ogg") {
        "ogg"
    } else if m.contains("mp4") || m.contains("m4a") || m.contains("aac") {
        "m4a"
    } else if m.contains("wav") {
        "wav"
    } else {
        "webm"
    }
}

/// Voice notes on disk: one folder per note holding `note.json` and the audio.
#[derive(Debug, Clone)]
pub struct VoiceNoteStore {
    pub root: PathBuf,
}

impl VoiceNoteStore {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    pub fn folder(&self, id: &str) -> Result<PathBuf, WorkspaceError> {
        if !is_safe_id(id) {
            return Err(WorkspaceError::new("That voice note's name isn't valid."));
        }
        Ok(self.root.join(id))
    }

    /// Every readable note, newest first.
    pub fn all(&self) -> Vec<VoiceNote> {
        let Ok(entries) = std::fs::read_dir(&self.root) else {
            return Vec::new();
        };
        let mut notes: Vec<VoiceNote> = entries
            .flatten()
            .filter_map(|e| {
                let name = e.file_name().to_string_lossy().to_string();
                if !is_safe_id(&name) {
                    return None;
                }
                let data = std::fs::read(e.path().join(FILE_NAME)).ok()?;
                VoiceNote::parse(&data).ok().filter(|n| n.id == name)
            })
            .collect();
        notes.sort_by_key(|n| std::cmp::Reverse(n.created_at));
        notes
    }

    pub fn note(&self, id: &str) -> Option<VoiceNote> {
        let data = std::fs::read(self.folder(id).ok()?.join(FILE_NAME)).ok()?;
        VoiceNote::parse(&data).ok()
    }

    /// Saves the note, setting `updated_at` to `now`.
    pub fn save(&self, note: &mut VoiceNote, now: Date) -> Result<(), WorkspaceError> {
        note.updated_at = Some(now);
        let dir = self.folder(&note.id)?;
        std::fs::create_dir_all(&dir).map_err(io)?;
        let tmp = dir.join(".note.json.partial");
        std::fs::write(&tmp, note.to_json()).map_err(io)?;
        std::fs::rename(&tmp, dir.join(FILE_NAME)).map_err(io)
    }

    /// Writes the recording as `audio.<ext>` in the note's folder.
    pub fn put_audio(
        &self,
        note: &mut VoiceNote,
        bytes: &[u8],
        ext: &str,
    ) -> Result<PathBuf, WorkspaceError> {
        let name = format!("audio.{ext}");
        if !is_safe_file_name(&name) || !ext.chars().all(|c| c.is_ascii_alphanumeric()) {
            return Err(WorkspaceError::new("That audio type isn't supported."));
        }
        let dir = self.folder(&note.id)?;
        std::fs::create_dir_all(&dir).map_err(io)?;
        let path = dir.join(&name);
        std::fs::write(&path, bytes).map_err(io)?;
        note.audio = Some(name);
        Ok(path)
    }

    pub fn audio_path(&self, note: &VoiceNote) -> Option<PathBuf> {
        let name = note.audio.as_deref().filter(|n| is_safe_file_name(n))?;
        Some(self.folder(&note.id).ok()?.join(name))
    }

    pub fn delete(&self, id: &str) -> Result<(), WorkspaceError> {
        let dir = self.folder(id)?;
        if dir.exists() {
            std::fs::remove_dir_all(dir).map_err(io)?;
        }
        Ok(())
    }
}

fn io(e: std::io::Error) -> WorkspaceError {
    WorkspaceError::new(format!("The voice note couldn't be saved: {e}"))
}

/// A transcription request for a local server: the endpoint and a multipart body.
///
/// `server` is what the user typed: `http://localhost:8080` (whisper.cpp's
/// server: `/inference`), or a base for OpenAI-style servers
/// (`/v1/audio/transcriptions`). A URL that already names a path is used as is.
pub struct TranscriptionRequest {
    pub url: String,
    pub content_type: String,
    pub body: Vec<u8>,
}

pub fn transcription_request(
    server: &str,
    audio: &[u8],
    file_name: &str,
    model: &str,
    language: Option<&str>,
    boundary: &str,
) -> Result<TranscriptionRequest, WorkspaceError> {
    let server = server.trim().trim_end_matches('/');
    let Some(rest) = server
        .strip_prefix("http://")
        .or_else(|| server.strip_prefix("https://"))
    else {
        return Err(WorkspaceError::new(
            "The transcription server's address should start with http:// or https://.",
        ));
    };
    let has_path = rest.contains('/');
    let url = if has_path {
        server.to_string()
    } else {
        format!("{server}/v1/audio/transcriptions")
    };
    let mut body = Vec::new();
    let mut field = |name: &str, value: &str| {
        body.extend_from_slice(
            format!(
                "--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n"
            )
            .as_bytes(),
        );
    };
    field(
        "model",
        if model.trim().is_empty() {
            "whisper-1"
        } else {
            model.trim()
        },
    );
    field("response_format", "verbose_json");
    if let Some(lang) = language
        .and_then(|l| l.split(['-', '_']).next())
        .filter(|l| !l.is_empty())
    {
        field("language", lang);
    }
    let mime = match file_name.rsplit('.').next().unwrap_or("") {
        "webm" => "audio/webm",
        "ogg" => "audio/ogg",
        "wav" => "audio/wav",
        _ => "audio/mp4",
    };
    body.extend_from_slice(
        format!("--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{file_name}\"\r\nContent-Type: {mime}\r\n\r\n")
            .as_bytes(),
    );
    body.extend_from_slice(audio);
    body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
    Ok(TranscriptionRequest {
        url,
        content_type: format!("multipart/form-data; boundary={boundary}"),
        body,
    })
}

/// The segments from a server's answer: `verbose_json` (`segments` with
/// `start`/`end`/`text`), or just `{"text": …}` as one segment over `duration`.
pub fn parse_transcription(data: &[u8], duration: f64) -> Result<Vec<Segment>, WorkspaceError> {
    let v: serde_json::Value = serde_json::from_slice(data)
        .map_err(|_| WorkspaceError::new("The transcription server's answer wasn't understood."))?;
    if let Some(list) = v.get("segments").and_then(|s| s.as_array()) {
        let segments: Vec<Segment> = list
            .iter()
            .filter_map(|s| {
                let text = s.get("text")?.as_str()?.trim().to_string();
                (!text.is_empty()).then(|| Segment {
                    start: s.get("start").and_then(|x| x.as_f64()).unwrap_or(0.0),
                    end: s.get("end").and_then(|x| x.as_f64()).unwrap_or(0.0),
                    text,
                })
            })
            .collect();
        if !segments.is_empty() {
            return Ok(segments);
        }
    }
    match v.get("text").and_then(|t| t.as_str()).map(str::trim) {
        Some(text) if !text.is_empty() => Ok(vec![Segment {
            start: 0.0,
            end: duration.max(0.0),
            text: text.to_string(),
        }]),
        _ => match v.get("error") {
            Some(e) => Err(WorkspaceError::new(format!(
                "The transcription server said: {}",
                e.get("message")
                    .and_then(|m| m.as_str())
                    .unwrap_or(&e.to_string())
            ))),
            None => Ok(Vec::new()),
        },
    }
}

/// Where voice notes live: `<data>/Voice Notes`.
pub fn folder_in(data: &Path) -> PathBuf {
    data.join("Voice Notes")
}
