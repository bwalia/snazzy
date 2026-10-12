# Recordings: `raw/`, `timeline.json`, chapters

A recording is laid out so it can be rendered again later with another inset,
arrangement or range (New Layout), on either platform.

Source of truth: `Packages/SnazzyKit/Sources/CaptureEngine/Recorder.swift`
(`RecordingSession.timeline`, called by `writeTimeline`), `Relayout.swift`
(`Recording.init(rawFolder:)`, what is read back), `Captions.swift` (`Chapters`).
Fixtures: `timeline.json`, `timeline-minimal.json`, `chapters.vtt`.
Rust: `snazzy_core::timeline`.

## Files

Under the recordings folder (`~/Movies/Snazzy Pro/Recordings/` on the Mac):

- `presentation-yyyyMMdd-HHmmss.mov`: the composite, H.264 + AAC, 1920×1080.
- `presentation-yyyyMMdd-HHmmss raw/` next to it:
  - `screen.mov`, `camera.mov` (HEVC, the camera's own frame times), `mic.mov` (PCM);
  - `timeline.json`.
- `presentation-yyyyMMdd-HHmmss.chapters.vtt` (only with two or more chapters).

Edits write siblings; originals are never changed.

## `timeline.json`

Compact JSON, sorted keys, `/` **not** escaped (`JSONValue.encoded()`); numbers
with no fraction as integers.

| Key | Value |
|---|---|
| `version` | `1` |
| `created` | recording start, `2026-01-02T03:04:05Z` |
| `duration_seconds` | length, pauses removed |
| `composite` | the composite's file name |
| `canvas` | `[1920, 1080]` |
| `fps` | `30` |
| `dropped_frames` | number |
| `files` | `{"camera":"camera.mov","mic":"mic.mov","screen":"screen.mov"}` |
| `inset` | `corner` (`topLeft`, `topRight`, `bottomLeft`, `bottomRight`), `size` (fraction of the height), `margin`, `border_width` (px at 1080p), `corner_radius` (fraction of the inset height), `rotation` (`none`, `left`, `right`, `upsideDown`), `zoom`, `center_x`, `center_y`, `aspect` (number, or `"fit"`), `video_delay_ms`, `background` (`CameraBackground` Codable: `{"none":{}}`, `{"blur":{"strength":0.6}}`, `{"color":{"hex":"#RRGGBB"}}`, `{"builtIn":{"id":…}}`, `{"image":{"id":…}}`), `title_slide_size` (number or `null`) |
| `camera_latency_ms` | median camera lateness, whole ms, or `null` |
| `camera_freezes` | `[{"at_seconds":…,"duration_seconds":…}]` |
| `markers` | events in raw-track time; slide changes are `{"type":"slide","index":0,"title":"…","title_slide":true,"at_seconds":0.512}` (`at_seconds` rounded to ms) |
| `composite_starts_at_seconds` | where the composite starts in raw-track time |
| `note` | the fixed explanation in the fixture |

Times are seconds from the start of the recording with pauses removed. The raw
tracks share this timeline; `camera.mov` keeps the camera's own times, so shift
it earlier by `inset.video_delay_ms` (lip sync: positive = picture behind the
sound) when laying it out again.

**Reading** (New Layout): every key is optional. Missing values fall back to the
defaults (`InsetLayout()`, the camera profile defaults), `aspect` that isn't a
number means fit, `camera_latency_ms` missing means 0. `duration_seconds` must be
over 0, and `screen.mov` must exist.

## Chapters

From the `slide` markers: `at = at_seconds − composite_starts_at_seconds`,
title = `title` (else `Slide <index+1>`). Clamp to 0…duration, sort, drop slides
shown under 1.5 s, merge repeats of the same title, start the first at 0. None
with fewer than two. WebVTT:

```
WEBVTT

1
00:00:00.000 --> 00:00:03.850
Title

2
…
```

Timestamps `HH:MM:SS.mmm` (ms rounded); newlines in titles become spaces and
`-->` becomes `→`.
