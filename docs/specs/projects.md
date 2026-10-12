# Projects

Each deck or prototype is a folder in the projects root (Mac:
`~/Library/Application Support/Snazzy Pro/Projects/`), served as
`snazzy-project://<folder>/`.

Source of truth: `Packages/SnazzyKit/Sources/Builder/Workspace.swift`.
Fixtures: `project.json`, `project-old.json`, `workspace-cases.json`.
Rust: `snazzy_core::{project, workspace}`.

## `.snazzy-project.json`

Pretty-printed, sorted keys, `\/`, ISO dates, no final newline:

```json
{
  "category" : "Finance",
  "created" : "2026-01-02T03:04:05Z",
  "kind" : "presentation",
  "name" : "q3-review",
  "origin" : "github:bwalia\/snazzy\/decks\/q3-review",
  "shared" : true,
  "tags" : [
    "Board",
    "Q3"
  ]
}
```

- Required: `name` (the folder name), `kind` (`presentation` or `prototype`), `created`.
- Optional, left out when unset: `shared` (only ever `true`: from someone else,
  no internet until allowed), `category`, `tags`, `origin` (`github:owner/repo/folder`).
  Older files have only the required keys (`project-old.json`).

**Category and tags** (`setDetails`): category trimmed, at most 60 characters,
blank removes it. Tags: trimmed, `#` removed, blanks and case-insensitive repeats
dropped (first wins), each cut to 40 characters, at most 20, none removes them.
`origin` is replaced only when given.

## Folder names

`slug(name)`: transliterate to Latin, strip accents, lower-case, split on
anything that isn't an ASCII letter or digit, join with `-`, cut to 60
characters; `project` when empty. `Café déjà vu` → `cafe-deja-vu`.

The Mac transliterates every script with ICU (`日本` → `ri-ben`,
`Привет мир` → `privet-mir`). **Rust strips accents from Latin, Greek and
Cyrillic letters only** (no ICU), so names in other scripts get different, still
valid, names there (`project` or the ASCII parts). The Rust tests skip those cases.

## Paths inside a project

`resolve(project, path)`, used for every read, write and delete:

1. Trim whitespace. Empty, or starting with `/` or `~`: "Use a relative path
   inside the project, like "index.html" or "js/app.js"." (Windows also refuses
   `\` and `:`.)
2. Resolve `.` and `..` lexically; anything not strictly inside the project
   (including the project folder itself): `Path "<path>" is outside the project.`
3. Any symlink on the way, even a dangling one: the same message. Projects never
   contain symlinks.
4. A last component starting with `.snazzy`: "That file is reserved."

Files are at most 2,000,000 bytes to write ("File too large (max 2 MB).") and to
read. Listing returns relative paths with `/`, sorted, without `.snazzy*` at the
top, symlinks skipped. Other hidden files are listed.
