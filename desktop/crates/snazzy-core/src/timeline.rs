//! `timeline.json` in a recording's `… raw/` folder (CaptureEngine/Recorder.swift
//! `RecordingSession.timeline`), what New Layout reads back
//! (CaptureEngine/Relayout.swift), and the `.chapters.vtt` made from its slide
//! markers (CaptureEngine/Captions.swift `Chapters`). Spec: docs/specs/recordings.md.

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::Value;

use crate::iso8601::Date;
use crate::json;

pub const FILE_NAME: &str = "timeline.json";
pub const NOTE: &str = "Times are seconds from the start of the recording with pauses removed. Raw tracks share this timeline; the composite movie begins at composite_starts_at_seconds. camera.mov keeps the camera's own times: shift it earlier by inset.video_delay_ms (lip sync) when laying it out again.";

/// Everything is optional when reading (older or newer recordings); a recording
/// written here has every field, `null` where the Mac writes `null`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Timeline {
    pub version: i64,
    pub created: Option<Date>,
    /// Seconds, pauses removed.
    pub duration_seconds: f64,
    /// The composite movie's file name.
    pub composite: String,
    /// Width, height.
    pub canvas: [f64; 2],
    pub fps: f64,
    pub dropped_frames: f64,
    pub files: Files,
    pub inset: Inset,
    /// Median lateness of camera frames, ms (null if unknown).
    pub camera_latency_ms: Option<f64>,
    pub camera_freezes: Vec<Freeze>,
    /// Events in raw-track time; `"type": "slide"` ones become chapters.
    pub markers: Vec<Value>,
    /// Where the composite movie starts in raw-track time.
    pub composite_starts_at_seconds: f64,
    pub note: String,
}

impl Default for Timeline {
    fn default() -> Self {
        Self {
            version: 1,
            created: None,
            duration_seconds: 0.0,
            composite: String::new(),
            canvas: [1920.0, 1080.0],
            fps: 30.0,
            dropped_frames: 0.0,
            files: Files::default(),
            inset: Inset::default(),
            camera_latency_ms: None,
            camera_freezes: vec![],
            markers: vec![],
            composite_starts_at_seconds: 0.0,
            note: NOTE.into(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Files {
    pub screen: String,
    pub camera: String,
    pub mic: String,
}

impl Default for Files {
    fn default() -> Self {
        Self {
            screen: "screen.mov".into(),
            camera: "camera.mov".into(),
            mic: "mic.mov".into(),
        }
    }
}

/// The camera inset the recording was made with (layout and the camera's profile).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Inset {
    /// topLeft, topRight, bottomLeft, bottomRight
    pub corner: String,
    /// Height as a fraction of the canvas height.
    pub size: f64,
    pub margin: f64,
    pub border_width: f64,
    pub corner_radius: f64,
    /// none, left, right, upsideDown
    pub rotation: String,
    pub zoom: f64,
    pub center_x: f64,
    pub center_y: f64,
    pub aspect: Aspect,
    /// Lip sync: picture behind the sound by this much (camera.mov keeps its own times).
    pub video_delay_ms: f64,
    /// `CameraBackground` as the Mac encodes it, e.g. `{"blur":{"strength":0.6}}`, `{"none":{}}`.
    pub background: Value,
    /// The inset size on title slides (null = off).
    pub title_slide_size: Option<f64>,
}

impl Default for Inset {
    fn default() -> Self {
        Self {
            corner: "bottomRight".into(),
            size: 0.28,
            margin: 0.025,
            border_width: 3.0,
            corner_radius: 0.06,
            rotation: "none".into(),
            zoom: 1.0,
            center_x: 0.5,
            center_y: 0.45,
            aspect: Aspect::Ratio(16.0 / 9.0),
            video_delay_ms: 0.0,
            background: serde_json::json!({"none": {}}),
            title_slide_size: None,
        }
    }
}

/// The crop's width/height, or "fit" (the whole picture).
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Aspect {
    Ratio(f64),
    Fit,
}

impl Serialize for Aspect {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        match self {
            Aspect::Ratio(r) => s.serialize_f64(*r),
            Aspect::Fit => s.serialize_str("fit"),
        }
    }
}

impl<'de> Deserialize<'de> for Aspect {
    /// Anything but a number means "fit", as in Relayout.
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        Ok(Value::deserialize(d)?
            .as_f64()
            .map_or(Aspect::Fit, Aspect::Ratio))
    }
}

impl Default for Aspect {
    fn default() -> Self {
        Aspect::Ratio(16.0 / 9.0)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct Freeze {
    pub at_seconds: f64,
    pub duration_seconds: f64,
}

impl Timeline {
    /// As the Mac writes it (`JSONValue.encoded()`: compact, sorted, `/` unescaped).
    pub fn to_json(&self) -> String {
        json::to_string(self, json::Style::COMPACT_UNESCAPED).unwrap_or_default()
    }

    pub fn parse(data: &[u8]) -> serde_json::Result<Timeline> {
        serde_json::from_slice(data)
    }

    /// The camera's lateness in seconds (0 if unknown), as Relayout uses it.
    pub fn camera_latency(&self) -> f64 {
        self.camera_latency_ms.unwrap_or(0.0) / 1000.0
    }

    /// A marker for a slide change at `at_seconds` (raw-track time, rounded to ms).
    pub fn slide_marker(index: usize, title: &str, is_title: bool, at_seconds: f64) -> Value {
        serde_json::json!({
            "type": "slide", "index": index as f64, "title": title, "title_slide": is_title,
            "at_seconds": (at_seconds * 1000.0).round() / 1000.0,
        })
    }

    /// The median of the measured camera latencies, rounded to whole ms.
    pub fn median_latency_ms(sorted_seconds: &[f64]) -> Option<f64> {
        (!sorted_seconds.is_empty())
            .then(|| (sorted_seconds[sorted_seconds.len() / 2] * 1000.0).round())
    }
}

/// A chapter mark, in seconds from the start of the movie.
#[derive(Debug, Clone, PartialEq)]
pub struct Mark {
    pub at: f64,
    pub title: String,
}

/// Slide markers as chapter marks, in seconds from `start` (the composite's start).
pub fn marks_from_timeline(markers: &[Value], start: f64) -> Vec<Mark> {
    markers
        .iter()
        .filter_map(|m| {
            if m.get("type")?.as_str()? != "slide" {
                return None;
            }
            let at = m.get("at_seconds")?.as_f64()?;
            let title = m
                .get("title")
                .and_then(Value::as_str)
                .map(str::to_string)
                .unwrap_or_else(|| {
                    let index = m
                        .get("index")
                        .and_then(Value::as_f64)
                        .map(f64::trunc)
                        .filter(|i| i.abs() < 9e15)
                        .unwrap_or(0.0) as i64;
                    format!("Slide {}", index + 1)
                });
            Some(Mark {
                at: at - start,
                title,
            })
        })
        .collect()
}

/// `00:01:02.345`
pub fn timestamp(seconds: f64) -> String {
    let ms = (seconds.max(0.0) * 1000.0).round() as i64;
    format!(
        "{:02}:{:02}:{:02}.{:03}",
        ms / 3_600_000,
        (ms / 60_000) % 60,
        (ms / 1000) % 60,
        ms % 1000
    )
}

/// A WebVTT chapters file: slides shown under `minimum` seconds are skipped,
/// repeats merged, the first starts at 0. None with fewer than two chapters.
pub fn chapters_vtt(marks: &[Mark], duration: f64, minimum: f64) -> Option<String> {
    let mut sorted: Vec<Mark> = marks
        .iter()
        .map(|m| Mark {
            at: m.at.max(0.0).min(duration),
            title: m.title.clone(),
        })
        .collect();
    sorted.sort_by(|a, b| a.at.total_cmp(&b.at));
    let mut kept: Vec<Mark> = Vec::new();
    for (i, m) in sorted.iter().enumerate() {
        let end = sorted.get(i + 1).map_or(duration, |n| n.at);
        if end - m.at < minimum || kept.last().is_some_and(|k| k.title == m.title) {
            continue;
        }
        kept.push(m.clone());
    }
    if kept.len() < 2 {
        return None;
    }
    kept[0].at = 0.0;
    let cues: Vec<String> = kept
        .iter()
        .enumerate()
        .map(|(i, m)| {
            let end = kept.get(i + 1).map_or(duration, |n| n.at);
            let title = m.title.replace('\n', " ").replace("-->", "→");
            format!(
                "{}\n{} --> {}\n{}\n",
                i + 1,
                timestamp(m.at),
                timestamp(end),
                title
            )
        })
        .collect();
    Some(format!("WEBVTT\n\n{}", cues.join("\n")))
}

/// `presentation-….mov` → `presentation-….chapters.vtt`.
pub fn chapters_file_name(movie: &str) -> String {
    let stem = movie.rsplit_once('.').map_or(movie, |(s, _)| s);
    format!("{stem}.chapters.vtt")
}
