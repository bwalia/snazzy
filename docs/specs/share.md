# `.snazzy` share files

A deck (a Builder project), presets and background images, sent between Snazzy
Pro users. **Never** API keys (they're only in the credential store, never in
presets), conversations or recordings.

Source of truth: `Packages/SnazzyKit/Sources/Builder/SnazzyShare.swift`.
Fixtures: `share-basic.snazzy` + `share-basic.json` (the JSON inside),
`share-empty.*`, `share-cases.json` (files to refuse and why, safe paths, limits),
`share-from-rust.snazzy` (written by Rust, opened by the Swift test).
Rust: `snazzy_core::share`.

## Layout

1. 8 bytes: `SNZSHR01`.
2. The JSON, compressed with **raw deflate** (RFC 1951, no zlib header or
   checksum: what `NSData.compressed(using: .zlib)` writes). The compressed
   bytes differ between compressors; the JSON inside is the contract.

JSON (compact, sorted keys, `\/`, see README):

```json
{"backgrounds":[{"data":"<base64>","id":"bg-1","name":"Studio wall"}],
 "created":"2026-01-02T03:04:05Z","format":"snazzy-share","note":"…",
 "presets":[<SettingsPreset, see settings.md>],
 "project":{"files":[{"data":"<base64>","path":"index.html"}],"kind":"presentation","name":"q3-review"},
 "title":"Q3 review","version":1}
```

`format`, `version`, `title`, `created`, `note`, `presets`, `backgrounds` are
required; `project` is optional. Unknown keys are ignored.

## Reading (in this order)

| Check | Message |
|---|---|
| File over 200,000,000 bytes | This file is too big to open. |
| No magic | This isn't a Snazzy Pro share file. |
| Not deflate | This share file is damaged. |
| Over 300,000,000 bytes when inflated (checked while inflating) | This file is too big to open. |
| JSON doesn't decode | This share file is damaged or from a newer version of Snazzy Pro. |
| `format` ≠ `snazzy-share` | This isn't a Snazzy Pro share file. |
| `version` > 1 | This file needs a newer version of Snazzy Pro. |
| Over 2,000 project files | Too many files in this project. |
| An unsafe path | Unsafe file path in share: `<path>` |
| A file over 50,000,000 bytes | `<path>` is too large to import. |
| Two paths equal ignoring case | Duplicate files in share. |
| Over 50 backgrounds or 50 presets | Too many items in this share file. |

**Safe path**: not empty, under 512 characters, not starting with `/` or `~`, no
`\`, no control characters (Unicode Cc), and every `/`-separated part non-empty,
not `.` or `..`, and not starting with `.`.

## Importing

- The project gets a free folder name: the slug of `project.name` (`shared` if
  empty), then `-2`, `-3`, ….
- Its `.snazzy-project.json` has `shared: true`: served with no internet access
  until the user allows it.
- Paths are checked again, then resolved inside the project (projects.md).
- Background images get new IDs; presets refer to them as
  `{"image":{"id":"…"}}` anywhere inside (an object with that single key), and are
  rewritten to the new IDs (`imageIDs`, `remapImages`).

Writing: refuse JSON over 300,000,000 bytes ("This is too big to share (over 300 MB).").
