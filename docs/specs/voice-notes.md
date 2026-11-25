# Voice notes

Something said out loud (a thought while talking, a brainstorm, a meeting), kept
as audio plus the words. Every app records them the same way, so a note made on
one device opens on another.

Source of truth: `Packages/SnazzyKit/Sources/SnazzyCore/VoiceNotes.swift`
(`VoiceNote`, `VoiceNoteStore`). Fixture: `voice-note.json`
(`Tests/SnazzyCoreTests/VoiceNoteTests.swift`). Rust: `snazzy_core::voice_notes`.

## Folder

One folder per note, named by its id, under the voice notes folder:

| App | Folder |
|---|---|
| Mac | `~/Movies/Snazzy Pro/Voice Notes/` |
| iPhone, iPad | the app's Documents, `Voice Notes/` (visible in the Files app) |
| Windows | `%APPDATA%\Snazzy Pro\Voice Notes\` |
| Linux | `$XDG_DATA_HOME/snazzy-pro/Voice Notes/` (default `~/.local/share`) |

Each folder holds `note.json` and, if the audio was kept, `audio.<ext>`
(`audio.m4a` on Apple devices, `audio.webm` or `audio.ogg` from Windows and Linux).

- Ids: 1–64 ASCII letters, digits, `-` or `_` (new notes use a lower-case UUID).
  A folder whose name isn't a valid id, or whose `note.json` has another id, is not a note.
- `audio` must be a plain file name in the folder: no `/`, `\`, leading `.`.
- Deleting a note deletes its folder.

## `note.json`

Pretty-printed, sorted keys, dates ISO 8601 in UTC with whole seconds (JSON as Swift writes it, see README).

| Key | Value |
|---|---|
| `format` | `"snazzy-voice-note"` (anything else: not a note) |
| `version` | `1` (higher: needs a newer app) |
| `id` | the folder's name |
| `title` | given by the user, or `""` |
| `created_at`, `updated_at` | `2026-01-02T03:04:05Z` |
| `duration` | seconds of audio (0 without audio) |
| `audio` | the audio file's name, or left out |
| `transcript` | the whole text: the segments joined with spaces, or typed/edited by hand |
| `segments` | `[{"start": 0, "end": 2.5, "text": "…"}]`, seconds into the audio; may be empty |
| `marks` | `[{"at": 4.2, "label": "Idea"}]`: moments marked while talking |
| `tags` | `["launch"]` |
| `device` | `Mac`, `iPhone`, `iPad`, `Windows` or `Linux` |
| `language` | BCP 47, e.g. `en-GB`, or left out |
| `transcribed_by` | `on-device`, `whisper-server`, `typed` or `none` |

**Reading:** every key except `id` is optional; missing values fall back to `""`,
`0`, `[]`, and `transcribed_by` to `none`, `updated_at` to `created_at`.

## Behaviour every app shares

- **Title shown:** `title` if not blank; else the first sentence of the transcript
  (split at `.`, `!`, `?` or a new line), at most 7 words, outer punctuation trimmed,
  first letter upper-cased; else "Voice note, <date>".
- **Search:** every word of the query appears in the shown title, transcript or tags,
  ignoring case and accents.
- **Edited text:** when `transcript` no longer equals the segments joined, show the
  transcript (the user's words) rather than the timed segments.
- **Paragraphs:** segments joined while the gap is under 2 s and the paragraph under 60 s.
- **Markdown** (copy/export): `# <title>`, the date and length in italics, `Tags: …`,
  `## Marked` with `- m:ss Label: “what was said”` (the last segment starting no
  later than 0.5 s after the mark), then `## Notes` with `**m:ss** paragraph`.
- Speech becomes text on the device that recorded it (Apple's on-device speech
  recognition), or on a transcription server the user runs themselves (Windows/Linux).
  Notes go to an AI model only when the user asks (Make a Deck, Summarise), through
  the app's usual consent for cloud models.
