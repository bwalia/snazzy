# Build prompt: Snazzy Pro for Windows and Linux (Rust)

Build **Snazzy Pro for Windows and Linux**: one Rust codebase, two desktop apps,
with the same features as Snazzy Pro for Mac and compatible with it. It is a
presentation studio you run by conversation: an AI agent plans and builds HTML
slide decks, sets up cameras, mics and screens, records screen + camera inset +
mic, runs a live classroom on the local network, streams to YouTube and others,
and is controlled from the existing iPhone, iPad and Apple Watch remotes.

Read `docs/plans/WINDOWS_LINUX.md` first. It records the decisions this prompt
builds on. The Mac app (Swift) is the reference for behaviour, and its code is
the specification for every shared format and protocol. **Don't port the Swift;
match what it does and what it writes.**

Build it in this repository, in a new top-level folder `desktop/` (a Cargo
workspace), so the shared spec fixtures live next to both apps and one CI runs
both. **Windows first, then Linux.**

---

## 0. Ground rules

- **Read before writing:** `CLAUDE.md`, `README.md`, `docs/plans/WINDOWS_LINUX.md`,
  `docs/business/PRO.md`, `decks/README.md`, and the Swift files named in §3.
- **Dependencies need approval.** Propose the crate list (name, version, licence,
  why) and wait for a yes before adding any. Record each in `THIRD_PARTY_NOTICES.md`.
  No GPL dependencies: the app is Apache-2.0 open core and the closed Pro package
  must be able to link with it. GStreamer and FFmpeg only in LGPL builds; no x264.
- **Secrets only in the OS credential store** (`keyring`: Windows Credential
  Manager, Linux Secret Service). Never in files, logs, settings, tool results or chat.
- **Privacy first.** Nothing leaves the computer unless the user turns it on and
  agrees. Ask before each stream, live room, upload, and the first use of a cloud
  model. Show when content goes to a cloud provider.
- **Never modify the user's originals.** Edits write siblings.
- **One code path for UI and agent.** A button and the agent's tool call the
  same function.
- **Commits:** DCO signed off (`git commit -s`). No API keys, tokens, signing
  material or personal paths, so check before every commit.
- **Warnings are errors:** `cargo clippy -- -D warnings`, `cargo fmt --check`,
  and `#![deny(unsafe_op_in_unsafe_fn)]`; keep `unsafe` to the platform layer,
  with a `// SAFETY:` comment on each block.

---

## 1. What the user can do (parity with the Mac app)

All from one window. The chat drives everything, and every action is also a
button or menu item.

1. **Make decks by asking.** "Make a 6-slide deck on our Q3 results." The agent
   writes `index.html` + `deck.css` + `deck.js` in a project folder and the
   preview updates live as files are written. A slide editor makes and edits
   decks without AI (`deck.json`).
2. **My Decks:** decks by name, grouped by category, filtered by tag; search
   across every slide's title, text and speaker notes, including samples
   (Ctrl+Shift+F); open a result at that slide. **Samples** for 12 sectors.
   **Get Decks** from GitHub deck repos (Snazzy Pro's `decks/` or any public repo).
3. **Present:** a Present window on any display with next/previous, speaker
   notes and a slide list.
4. **Set up:** "Use my USB mic, record the second screen, put my webcam
   bottom-right." Devices are listed and chosen, and live previews show framing.
5. **Record:** slides, a display or a window, with a camera inset and mic.
   Pause and resume. Chapters from slide changes. Save automatically, with no
   dialogs. Keep raw tracks plus `timeline.json` so **New Layout** can re-render
   later, including vertical 9:16 clips and parts.
6. **Camera Prompter:** notes or a script scrolling under the camera at reading
   speed, never captured.
7. **Voice Mode:** hands-free commands ("next slide", "start recording"), the
   wake word "Snazzy" while recording or live, and spoken replies. The mic is
   muted in every output while the app speaks.
8. **Live classroom:** a room on the local network. People join from a browser
   with a QR code and room code, watch the live picture, and post and vote on a
   brainstorm board. The agent turns the ideas into a deck.
9. **Go live:** RTMP(S) to YouTube, LinkedIn, Twitch, Vimeo, Facebook or a
   custom server, several at once, with reconnects. Stream keys are kept in the
   credential store.
10. **Remotes:** the existing iPhone/iPad/Watch apps pair with a QR code and
    control recording, slides, prompter and the assistant, **unchanged**.
11. **MCP:** a local MCP server (loopback, bearer token) exposes every tool to
    Claude Code, Cursor and others. The agent can also use MCP servers the user adds.
12. **Share:** `.snazzy` files to send a deck, presets and backgrounds;
    double-click to import. Imported or downloaded decks have no internet access
    until the user allows it.
13. **Human in the loop:** irreversible or public actions (stream, live room,
    deletes, agent actions over MCP) wait for an OK in a dialog.

---

## 2. Stack

| Area | Choice |
|---|---|
| App shell, UI | **Tauri 2**: a Rust core with an HTML/TS front end (keep it framework-light: plain TS or Svelte, agreed before adding). Fallback: Slint, if the web UI limits us. |
| Slides | The deck's own HTML in the system web view: **WebView2** on Windows, **WebKitGTK** on Linux, served from a custom protocol (`snazzy-project://<slug>/`) with path confinement and a CSP. |
| Media | **GStreamer** via `gstreamer-rs`: capture, compositing, encoding, muxing, RTMP. Hardware encoders first. |
| Async, servers | `tokio`; `hyper` for the Live room and MCP servers. |
| Discovery | `mdns-sd`: Bonjour `_snazzyremote._tcp`. |
| Remote TLS | `openssl` (TLS 1.2 PSK; `rustls` has no external PSK). |
| Secrets | `keyring`. |
| AI | HTTP clients for **Anthropic** (Messages API, SSE streaming, tool use) and **Ollama** (`/api/chat`, NDJSON, tools). Ollama plays the role of Apple's on-device model. |
| Segmentation | ONNX Runtime (background blur/replace), optional and behind a setting. |
| Speech | To be agreed: Windows `Windows.Media.SpeechRecognition` and OneCore voices (via the `windows` crate); on Linux a local engine (whisper.cpp for recognition, Piper or speech-dispatcher for speech). On-device only, like the Mac. |

Platform differences live in a thin layer selected with `#[cfg(target_os = ...)]`,
mostly GStreamer element names and caps:

| | Windows | Linux |
|---|---|---|
| Screen | `d3d11screencapturesrc` (Windows Graphics Capture) | `pipewiresrc` via the ScreenCast portal (Wayland), `ximagesrc` fallback on X11 |
| Camera | `mfvideosrc` | `v4l2src` / `pipewiresrc` |
| Mic | `wasapi2src` | `pipewiresrc` / `pulsesrc` |
| Encoder | `nvh264enc`, `amfh264enc`, `qsvh264enc`, then `openh264enc` | `nvh264enc`, `vah264enc`, then `openh264enc` |
| Exclude own windows from capture | `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)` | Not generally possible on Wayland. Put the prompter and previews on another screen, or record a window; say so in the UI |
| Packaging | MSIX/MSI, code-signed | AppImage and Flatpak (portals), then .deb |

---

## 3. Compatibility contracts (write these first)

Write each as a spec in `docs/specs/` with **test fixtures generated from the Swift
code**, and add tests to **both** codebases: Swift tests in `Packages/SnazzyKit/Tests`
and Rust tests in `desktop/`. A format change then fails one side or the other.

| Contract | Swift reference | What must match |
|---|---|---|
| Remote protocol | `Remote/RemoteProtocol.swift`, `RemoteSecurity.swift`, `RemoteHost.swift`, `WatchLink.swift`, `RemoteTests.swift` | 4-byte length + JSON frames, max 1 MB; `RemoteProtocol.version`; every `RemoteCommand`/`RemoteStatus` field (new status fields optional); unknown messages skipped, not fatal; TLS 1.2 PSK with `TLS_PSK_WITH_AES_128_GCM_SHA256`, identities `pair:<hostID>` and `dev:<deviceID>`; `hello` HMAC-SHA256 proof of the device ID; the pairing QR link `snazzypro://pair?…`; Bonjour `_snazzyremote._tcp`; status pushed when it changes (polled every 250 ms) |
| `.snazzy` files | `Builder/SnazzyShare.swift` | magic `SNZSHR01`, compression, `version`, limits, safe paths; never keys, conversations or recordings |
| Recordings | `CaptureEngine/Recorder.swift` (`writeTimeline`), `Relayout.swift` | the `… raw/` folder (`screen`, `camera`, `mic`), `timeline.json` keys (`version`, `inset`, `markers`, `camera_latency_ms`, `video_delay_ms`, `composite_starts_at_seconds`, …), `.chapters.vtt`; a recording from one platform re-lays out on the other |
| Decks | `Builder/Templates.swift`, `DeckOutline.swift`, `SampleDecks.swift`, `DeckSearch.swift` | `window.snazzyDeck = {show, count, current}`, `<section class="slide">`, `<aside class="notes">`; `deck.json`; `.snazzy-project.json` (`name`, `kind`, `created`, `shared`, `category`, `tags`, `origin`); the 12 samples; search results for the same query |
| Deck repos | `Builder/DeckRepo.swift`, `decks/README.md` | what people may paste, how deck folders are found, `snazzy-decks.json`, file limits, imports are `shared` |
| Live room | `Live/LiveServer.swift`, `LiveViewerPage.swift`, `BrainstormBoard.swift` | ports 8787–8790, room code, `/api/events` (SSE), `/api/board`, `/api/status`, `POST /api/notes`, `POST /api/vote`, the viewer page, fMP4/HLS segments, per-device limits |
| MCP server | `MCP/MCPServerCore.swift`, `MCPHTTPServer.swift`, `App/Sources/MCPManager.swift` | `127.0.0.1:47823/mcp`, bearer token, both protocol eras (modern stateless and legacy `initialize`/session), read-only hints for `get_`/`list_`/`check_`/`read_`/`search_` tools |
| Agent tools | `App/Sources/AssistantTools.swift`, `DeveloperTools.swift` | the same tool names, schemas (`additionalProperties: false`), confirmation rules and `external` wrapping (`<external_data>`), so prompts and the Claude Code plugin work on every platform |
| Settings | `SnazzyCore/AppSettings.swift`, `PresetStore.swift` | the same fields and tolerant decoding (every new field has a default), so presets in `.snazzy` files load everywhere |

---

## 4. The agent

- **The loop** (as `ConversationRunner`):
  1. Stream the model's reply.
  2. Validate each tool call against its JSON schema.
  3. Confirm tools marked `requires_confirmation`.
  4. Run the tools and send the results back.
  5. Repeat for at most 12 rounds; stop and ask after 2 invalid rounds in a row.
- **Anthropic:** default `claude-opus-5-5`, with `claude-sonnet-5-5` for quick
  commands.
  - Adaptive thinking.
  - Prompt caching with the top-level `cache_control`.
  - Server-side context management (`clear_tool_uses_20250919`).
  - **History is append-only, and thinking blocks are echoed back untouched.**
    Never edit or trim what is sent.
- **Ollama:** local or on another computer. Decide "does this leave the
  computer" from the configured host, never from the provider type. Trim old
  tool payloads for Ollama only. Strip stray tool-call markup from replies.
- **Model per task:** Planning, Writing, Building, Quick commands.
- **Off-computer review:** screen text and code going to a cloud model are
  redacted (`SecretRedactor` rules) and shown to the user first. Text from
  outside (audience, web, GitHub, files from others) is wrapped as external data.

---

## 5. Capture, recording and streaming (the hard part)

- **One clock.** Every source is timestamped on the pipeline clock, and the
  sound is never matched up afterwards.
- **Pull model, like the Mac:** each source keeps its latest frame. Screens and
  some cameras only send frames when something changes; that is not end of stream.
- **Compositor:** 1920×1080 (`compositor` or `glvideomixer`). The camera is
  rotated, then cropped, scaled, given rounded corners or a border, and positioned
  (`InsetGeometry`). Previews, the recorder, the live encoder and the RTMP outputs
  all read the **same** composite, so the preview matches the output.
- **Outputs at once:**
  - the composite MP4/MOV (H.264 + AAC);
  - raw `screen` and `camera` tracks plus `mic` (PCM), with `timeline.json` and
    `.chapters.vtt`;
  - the live room's fMP4 segments;
  - one RTMP pipeline per destination.

  A failing output never stops the others.
- **Crash-safe files:** fragmented MP4 (`mp4mux fragment-duration` or
  `splitmuxsink`), written under a hidden `.partial` name and renamed at the end.
  A crash leaves a playable file.
- **Lip sync:** each camera has a per-device delay (positive = picture behind the
  sound). Calibrate it with a clap (`SyncCalibration`), and offer a manual ± ms slider.
- **Stalls:** if a camera sends no frame for more than 2 s, show it, restart that
  source, and mark the freeze in the timeline. Screen and mic keep recording.
- **Mic muting while the app speaks:** replace mic samples with silence (same
  timing) in every output, as `MicMute` does.
- **Disk:** check free space before recording and while recording. Stop cleanly
  and keep what was recorded.
- **New Layout:** re-render from `raw/` + `timeline.json` with another inset,
  arrangement (`stacked` for 9:16) or time range.

---

## 6. Windows and Linux specifics

- **Wayland screen capture goes through the portal,** and the user picks the
  screen or window each time unless the portal allows restoring it (use
  `restore_token`). Say what's happening in the UI.
- **Permissions:**
  - Windows asks for camera and mic in Settings › Privacy.
  - Linux needs portal access (Flatpak) or group membership for `/dev/video*`.
  - Detect each case and show the exact fix.
- **Firewall:** the live room and remote host listen on the LAN. On Windows, ask
  to add a firewall rule for private networks only, and explain it.
- **Multi-monitor and HiDPI:** the Present window and prompter go on a chosen display.
- **Phones as cameras:** use any webcam the OS exposes. The Mac's
  iPad-over-USB capture is Mac-only; don't attempt it.

---

## 7. Repository layout

```
desktop/
  Cargo.toml                 # workspace
  crates/
    snazzy-core/             # settings, secrets, workspace, decks, search, .snazzy, specs
    snazzy-agent/            # providers, loop, tools registry, schema validation, MCP client
    snazzy-media/            # GStreamer pipelines: capture, compositor, recorder, relayout, rtmp
    snazzy-live/             # live room server, viewer page, board
    snazzy-remote/           # remote host: framing, TLS-PSK, pairing, mDNS
    snazzy-mcp/              # MCP server
    snazzy-platform/         # cfg(windows)/cfg(linux): capture exclusion, speech, firewall, paths
  app/                       # Tauri app (src-tauri + UI)
docs/specs/                  # contracts + fixtures shared with the Mac app
```

Pure logic stays in crates with unit tests and no UI. Storage paths:
- **Windows:** `%APPDATA%\Snazzy Pro\` for data, `Videos\Snazzy Pro\` for recordings.
- **Linux:** `$XDG_DATA_HOME/snazzy-pro/` for data, `$XDG_VIDEOS_DIR/Snazzy Pro/` for recordings.

CI: GitHub Actions `windows-latest` and `ubuntu-latest`, running fmt, clippy,
tests and a build, alongside the existing macOS jobs.

---

## 8. Phases (deliver and verify each before the next)

1. **Contracts:** `docs/specs/` plus fixtures from the Swift code; Rust parsers and
   tests for the remote framing, `.snazzy`, `timeline.json`, `deck.json`, project
   files, deck-repo discovery and search.
2. **Skeleton:** Tauri app, settings, credential store, chat with Ollama and
   Anthropic (streaming, tools), CI on both OSes.
3. **Decks:**
   - the Builder (project files, live preview, `snazzy-project://`, CSP, navigation guard);
   - the slide editor;
   - samples;
   - My Decks (categories, tags, search);
   - Get Decks;
   - the Present window;
   - `.snazzy` import and export.
4. **Agent tools and the MCP server:** the same names and schemas, plus confirmations.
5. **Devices and preview:** list and choose mics, cameras, displays and windows;
   live previews; inset geometry; presets.
6. **Recording:** composite + raw tracks + `timeline.json` + chapters, pause and
   resume, stalls, disk checks, crash-safe files. Then lip sync and New Layout.
7. **Live room and RTMP:** the same viewer page and API; several destinations;
   reconnects.
8. **Remote host:** pairing QR, TLS-PSK, the `hello` proof, Bonjour, status
   pushes. Test with the real iPhone and Watch apps.
9. **Voice Mode and Camera Prompter.**
10. **Packaging:** MSIX/MSI signed (Azure Trusted Signing), AppImage and Flatpak;
    auto-update channel; Downloads page entries on snazzy.pro.

---

## 9. Acceptance checks

- **Tooling:** fmt, clippy (`-D warnings`) and tests pass on Windows and Linux CI.
- **Fixtures:** every contract fixture passes in both the Swift and Rust tests.
- **Files from a Mac open on Windows/Linux, and the other way round:** a `.snazzy`
  file, a deck, and a recording's `raw/` + `timeline.json` (New Layout works on both).
- **Remotes:** the shipping iPhone app pairs with the Windows app by QR code, then
  controls recording and slides and shows notes. The Watch relays through the iPhone.
- **Live room:** a browser on another device joins, watches with under 3 s of
  delay on Wi-Fi, posts and votes.
- **Recording:**
  - A 30-minute 1080p30 recording on a mid-range laptop with a hardware encoder:
    no dropped audio; lips in sync within ±40 ms after calibration.
  - The file plays in VLC and the OS player.
  - Unplugging the webcam mid-recording keeps screen and mic going.
  - Killing the app mid-recording leaves a playable file.
- **Prompter:** on Windows, it never appears in recordings, the live room or
  streams. On Linux, the UI explains the limitation.
- **Offline:** with no network, Ollama still works and cloud models say they're
  unavailable.
- **Nothing sensitive in the output:** no keys, tokens or personal paths in the
  repo, logs or settings files.

---

## 10. Out of scope for now

- macOS: the Swift app stays.
- Apple's on-device model.
- iPad-over-USB cameras.
- Pro features (separate private package, `docs/business/PRO.md`).
- Store distribution (Microsoft Store, Snap Store) until the direct downloads are solid.
