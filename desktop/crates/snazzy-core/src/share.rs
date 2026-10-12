//! `.snazzy` share files (Builder/SnazzyShare.swift): the magic `SNZSHR01`, then
//! the JSON compressed with raw deflate (what `NSData.compressed(using: .zlib)`
//! writes: no zlib header or checksum). Read defensively: size caps while
//! inflating, path checks before anything touches the disk. Never carries API
//! keys, conversations or recordings. Spec: docs/specs/share.md.

use std::io::{Read, Write};

use flate2::Compression;
use flate2::read::DeflateDecoder;
use flate2::write::DeflateEncoder;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::WorkspaceError;
use crate::b64;
use crate::iso8601::Date;
use crate::json;
use crate::project::ProjectKind;
use crate::settings::SettingsPreset;

pub const FILE_EXTENSION: &str = "snazzy";
pub const MAGIC: &[u8; 8] = b"SNZSHR01";
pub const FORMAT: &str = "snazzy-share";
pub const VERSION: i64 = 1;

// Limits for files received from others.
pub const MAX_COMPRESSED_BYTES: usize = 200_000_000;
pub const MAX_EXPANDED_BYTES: usize = 300_000_000;
pub const MAX_FILES: usize = 2_000;
/// Per file: decks carry images and short videos, not whole films.
pub const MAX_FILE_BYTES: usize = 50_000_000;
pub const MAX_IMAGES: usize = 50;
pub const MAX_PRESETS: usize = 50;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Share {
    pub format: String,
    pub version: i64,
    pub title: String,
    pub created: Date,
    /// Optional note from the sender ("Here's the deck for Monday").
    pub note: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project: Option<Project>,
    pub presets: Vec<SettingsPreset>,
    pub backgrounds: Vec<Image>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Project {
    pub name: String,
    pub kind: ProjectKind,
    pub files: Vec<File>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct File {
    pub path: String,
    #[serde(with = "b64::serde_bytes")]
    pub data: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Image {
    /// The ID presets use to refer to it (`{"image": {"id": …}}`).
    pub id: String,
    pub name: String,
    #[serde(with = "b64::serde_bytes")]
    pub data: Vec<u8>,
}

impl Share {
    pub fn new(
        title: &str,
        note: &str,
        project: Option<Project>,
        presets: Vec<SettingsPreset>,
        backgrounds: Vec<Image>,
        created: Date,
    ) -> Self {
        Self {
            format: FORMAT.into(),
            version: VERSION,
            title: title.into(),
            created,
            note: note.into(),
            project,
            presets,
            backgrounds,
        }
    }

    pub fn is_empty(&self) -> bool {
        self.project.is_none() && self.presets.is_empty() && self.backgrounds.is_empty()
    }

    /// The JSON inside the file: compact, sorted keys, `\/`, ISO dates, base64 data.
    pub fn to_json(&self) -> Result<Vec<u8>, WorkspaceError> {
        json::to_vec(self, json::Style::COMPACT).map_err(|e| WorkspaceError::new(e.to_string()))
    }

    pub fn encode(&self) -> Result<Vec<u8>, WorkspaceError> {
        let json = self.to_json()?;
        if json.len() > MAX_EXPANDED_BYTES {
            return Err(WorkspaceError::new(
                "This is too big to share (over 300 MB).",
            ));
        }
        let mut encoder = DeflateEncoder::new(MAGIC.to_vec(), Compression::default());
        encoder
            .write_all(&json)
            .and_then(|_| encoder.finish())
            .map_err(|e| WorkspaceError::new(e.to_string()))
    }

    pub fn decode(data: &[u8]) -> Result<Share, WorkspaceError> {
        if data.len() > MAX_COMPRESSED_BYTES {
            return Err(WorkspaceError::new("This file is too big to open."));
        }
        if !data.starts_with(MAGIC) {
            return Err(WorkspaceError::new("This isn't a Snazzy Pro share file."));
        }
        let json = inflate(&data[MAGIC.len()..], MAX_EXPANDED_BYTES)?;
        let share: Share = serde_json::from_slice(&json).map_err(|_| {
            WorkspaceError::new("This share file is damaged or from a newer version of Snazzy Pro.")
        })?;
        if share.format != FORMAT {
            return Err(WorkspaceError::new("This isn't a Snazzy Pro share file."));
        }
        if share.version > VERSION {
            return Err(WorkspaceError::new(
                "This file needs a newer version of Snazzy Pro.",
            ));
        }
        share.validate()?;
        Ok(share)
    }

    /// Checks everything that will be written to disk on import.
    pub fn validate(&self) -> Result<(), WorkspaceError> {
        if let Some(p) = &self.project {
            if p.files.len() > MAX_FILES {
                return Err(WorkspaceError::new("Too many files in this project."));
            }
            for f in &p.files {
                if !is_safe_relative_path(&f.path) {
                    return Err(WorkspaceError::new(format!(
                        "Unsafe file path in share: {}",
                        f.path
                    )));
                }
                if f.data.len() > MAX_FILE_BYTES {
                    return Err(WorkspaceError::new(format!(
                        "{} is too large to import.",
                        f.path
                    )));
                }
            }
            // Case-insensitively: on a Mac (and Windows) "A.html" and "a.html" are the same file.
            let unique: std::collections::HashSet<String> =
                p.files.iter().map(|f| f.path.to_lowercase()).collect();
            if unique.len() != p.files.len() {
                return Err(WorkspaceError::new("Duplicate files in share."));
            }
        }
        if self.backgrounds.len() > MAX_IMAGES || self.presets.len() > MAX_PRESETS {
            return Err(WorkspaceError::new("Too many items in this share file."));
        }
        Ok(())
    }
}

/// Raw deflate with an output cap.
pub fn inflate(data: &[u8], limit: usize) -> Result<Vec<u8>, WorkspaceError> {
    let mut out = Vec::new();
    let mut decoder = DeflateDecoder::new(data).take(limit as u64 + 1);
    decoder
        .read_to_end(&mut out)
        .map_err(|_| WorkspaceError::new("This share file is damaged."))?;
    if out.len() > limit {
        return Err(WorkspaceError::new("This file is too big to open."));
    }
    Ok(out)
}

/// Relative, no `..`, no hidden or empty components, no backslashes or control
/// characters, under 512 characters.
pub fn is_safe_relative_path(path: &str) -> bool {
    if path.is_empty()
        || path.chars().count() >= 512
        || path.starts_with('/')
        || path.starts_with('~')
        || path.contains('\\')
    {
        return false;
    }
    if path.chars().any(char::is_control) {
        return false;
    }
    path.split('/')
        .all(|p| !p.is_empty() && p != "." && p != ".." && !p.starts_with('.'))
}

/// IDs of background images a preset uses (`{"image": {"id": …}}` anywhere in it).
pub fn image_ids(preset: &SettingsPreset) -> std::collections::BTreeSet<String> {
    fn walk(v: &Value, ids: &mut std::collections::BTreeSet<String>) {
        match v {
            Value::Object(o) => {
                if o.len() == 1 {
                    if let Some(id) = o
                        .get("image")
                        .and_then(|i| i.get("id"))
                        .and_then(Value::as_str)
                    {
                        ids.insert(id.to_string());
                    }
                }
                o.values().for_each(|c| walk(c, ids));
            }
            Value::Array(a) => a.iter().for_each(|c| walk(c, ids)),
            _ => {}
        }
    }
    let mut ids = std::collections::BTreeSet::new();
    if let Ok(v) = serde_json::to_value(preset) {
        walk(&v, &mut ids);
    }
    ids
}

/// The preset with background image IDs replaced (images get new IDs on import).
pub fn remap_images(
    preset: &SettingsPreset,
    map: &std::collections::HashMap<String, String>,
) -> SettingsPreset {
    fn walk(v: Value, map: &std::collections::HashMap<String, String>) -> Value {
        match v {
            Value::Object(o) => {
                if o.len() == 1 {
                    if let Some(new) = o
                        .get("image")
                        .and_then(|i| i.get("id"))
                        .and_then(Value::as_str)
                        .and_then(|id| map.get(id))
                    {
                        return serde_json::json!({"image": {"id": new}});
                    }
                }
                Value::Object(o.into_iter().map(|(k, c)| (k, walk(c, map))).collect())
            }
            Value::Array(a) => Value::Array(a.into_iter().map(|c| walk(c, map)).collect()),
            other => other,
        }
    }
    if map.is_empty() {
        return preset.clone();
    }
    serde_json::to_value(preset)
        .ok()
        .and_then(|v| serde_json::from_value(walk(v, map)).ok())
        .unwrap_or_else(|| preset.clone())
}
