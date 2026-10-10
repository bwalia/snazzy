# Snazzy Pro

A presentation studio for the Mac that you run by conversation (Swift, SwiftUI,
macOS 15+). It plans your talk, builds the slides, frames your camera and
records the video, then takes it live: a classroom room on your Wi-Fi with a
brainstorm board, or YouTube, Twitch and Vimeo. An iPhone/iPad app is the
remote and teleprompter, and an Apple Watch app (inside the iPhone app)
starts, pauses and stops recording and changes slides. The assistant uses local (Ollama, Apple on-device) or
cloud (Anthropic) models.
Website: https://www.snazzy.pro/ (source in `site/`, deployed by
`.github/workflows/pages.yml`). Brand: `docs/brand/`. Launch plan: `docs/launch/APP_STORE.md`.
Phase plan: `ROADMAP.md`.

**Status: recording, slides, sharing, live classroom, live streaming and the
iPhone/iPad remote (phase 9 core) done; preparing the Mac App Store launch.**
Phase 1 added the XcodeGen project, Keychain-stored keys and streaming chat
with tool calling (Ollama, Anthropic). Phase 2 adds device discovery, live
camera/iPad feeds with stall detection, per-device crop/rotation, floating
previews that stay out of recordings, and chat tools to drive all of it.

## Build, test, run

```sh
xcodegen
xcodebuild -scheme SnazzyPro -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/SnazzyPro.app

# Unit tests (fast, no network)
swift test --package-path Packages/SnazzyKit
# Also exercise the real Keychain
SNAZZY_KEYCHAIN_TESTS=1 swift test --package-path Packages/SnazzyKit

# Headless self-test inside the sandboxed app: Keychain, Ollama chat + tool call,
# and Anthropic if a key is in the Keychain (or ANTHROPIC_API_KEY is set)
build/DerivedData/Build/Products/Debug/SnazzyPro.app/Contents/MacOS/SnazzyPro --self-test \
    [--ollama-model gpt-oss:120b] [--anthropic-model claude-opus-5-5]

# Devices: list everything (waits for an iPad/iPhone), then stream one feed
SnazzyPro --self-test --devices [--feed "iPad"] [--seconds 5]
# Render a builder project off-screen: console report + a PNG per slide
SnazzyPro --self-test --builder-snapshot q3-devops --slides 3
# MCP: Snazzy Pro's server, and chat using an external MCP server
SnazzyPro --self-test --mcp-server
SnazzyPro --self-test --mcp-url https://mcp.context7.com/mcp --mcp-name Context7 --chat "Look up …"
# Record N seconds (main display + first iPad/iPhone + default mic) and inspect the files
SnazzyPro --self-test --record 6 [--pause-at 3] [--display LG] [--feed iPad]
# One frame of the composite from the live screen + camera
SnazzyPro --self-test --composite
# One chat turn with every app tool, printing the tool calls
SnazzyPro --self-test --chat "Put my iPad camera bottom-left and open a preview" [--provider anthropic --model claude-opus-5-5]
# Apple Watch remote, end to end in the simulators (Mac → iPhone → Watch);
# see docs/testing/WATCH_REMOTE.md for the manual checklist and real devices
Scripts/watch-sim-test.sh [seconds]
```

Warnings are treated as errors in the app target.

## Layout

| Path | What |
|---|---|
| `project.yml` | XcodeGen spec (generates `SnazzyPro.xcodeproj`, `App/Info.plist`, entitlements) |
| `App/Sources` | SwiftUI app: main window (chat + side panel), settings, chat session, self-test |
| `Packages/SnazzyKit` | Local Swift package, one module per area |
| ↳ `SnazzyCore` | Settings, Keychain secret store, `JSONValue`, logging |
| ↳ `Assistant` | `ModelProvider` protocol, Anthropic + Ollama providers, tool registry, JSON-schema validation, conversation loop |
| ↳ `CaptureEngine` | Device catalog (mics, cameras, USB iPad/iPhone, displays, windows), camera feeds with stall detection and restart, inset transform (rotate → crop), Metal preview view, diagnostics |
| ↳ `Builder` | Builder workspace (projects, safe file access, starter templates), partial-JSON reader for streamed tool input |
| ↳ `Slides` | Present the open Builder deck (slide list, speaker notes, Record This Deck): the "slides" source records its Present window directly, and slide changes become chapters. Plus sample decks for 12 sectors. |
| ↳ Decks library | Slides › **My Decks**: every deck by name, grouped by category, filtered by tag (set them with *Category & Tags…*). Search finds words in slide titles, text and speaker notes across all decks and the samples, and opens the deck at that slide (File › Find in Slides…, ⇧⌘F). Slides › **Get Decks**: add decks from [Snazzy Pro's deck repo](decks/) or any public GitHub repo (paste `owner/repo` or a link); they open offline until you allow the internet. The assistant can do all of this too (`search_slides`, `list_decks`, `open_deck`, `set_deck_details`, `list_github_decks`, `add_github_deck`). |
| ↳ Sharing | `.snazzy` files: send a deck or prototype, presets and their background images to another Snazzy Pro user with AirDrop, Messages, Mail or Save As (File › Share…, ⇧⌘S); double-click to import. No API keys, conversations or recordings. An imported project opens offline: its pages can't reach the internet (Content-Security-Policy) until you allow it, and no page can navigate the preview to another site. |
| ↳ Live classroom | Live tab: a room on your Wi-Fi. People scan a QR code and watch the live picture (slides or screen + camera, with your mic) in their browser, and post and vote on ideas on a brainstorm board; the assistant turns the ideas into a deck. Peer to peer from your Mac: no servers, accounts or internet. Room code required. Limits apply per device (by IP address): posts, one vote per idea, connections and wrong-code guesses, so one device can't flood or block the room. |
| ↳ Go live online | Stream the same picture and mic to YouTube, Twitch, Vimeo, Facebook or any RTMP(S) server (Live tab). Stream keys stay in the Keychain; it asks before every stream. A destination that drops reconnects (3 tries, 2–6 s apart); if the stream is lost for good, the copy recorded on the Mac keeps going. Uses HaishinKit (BSD-3-Clause); see THIRD_PARTY_NOTICES.md. |

## Assistant design

- `ModelProvider.stream(_:)` returns deltas (text, thinking, tool-call started) and
  ends with one `.completed` event that carries the whole assistant message, so
  every provider produces the same history.
- Anthropic: Messages API over SSE, adaptive thinking with summaries, `effort`
  from settings, `eager_input_streaming` on tools, and server-side refusal
  fallbacks (`fallbacks: "default"`) on models that support them. Thinking blocks
  are stored opaquely and sent back unchanged; history is append-only.
- Anthropic prompt caching covers the whole prefix (tools, system and history).
  Long chats rely on server-side context editing, which clears old tool calls and
  results past about 150k input tokens and keeps the latest six. History is never
  trimmed on the Mac, because that would invalidate thinking blocks.
- Ollama: `/api/chat` NDJSON with `tools`; `num_ctx` raised to 32k. Tool calls
  and results older than the last 8 messages are cut to 1,500 characters so
  that long chats still fit.
- Every tool call is validated against its JSON schema. An invalid call gets the
  error back so the model can retry once; a second invalid round stops and asks
  the user. Tools marked `requiresConfirmation` show a confirmation alert first.
- Text from outside the app (MCP servers, live-room ideas, web pages and
  project files, GitHub, screen text) comes back wrapped in `<external_data>`,
  and the model is told never to follow instructions in it.
- The chat header shows the task, model, local/cloud badge (it pulses while
  sending to a cloud provider), token use, and a warning when offline or when a
  key is missing.

## For developers

Five features, each switched on or off in **Settings › Developer** and
reachable by a sentence or a button (**Help › Snazzy Pro for Developers** lists
them). Everything works offline with a local model; with a cloud model, the
exact text is shown and approved first. Originals are never changed.

| Feature | Tools | Notes |
|---|---|---|
| Trim | `list_recordings`, `trim_recording` | Pass-through export to `<name> (trimmed).mp4`; raw tracks trimmed in step; Apple's trim view in the **Recordings** tab |
| Captions and summary | `make_captions`, `summarize_recording` | On-device `SpeechAnalyzer` → `.srt`/`.vtt`, optional `(captioned).mp4`; summary `.md` by the Writing model; text only, never audio |
| Share links (off by default) | `share_recording` | Own S3/R2/MinIO bucket (SigV4, time-limited link), GitHub release asset, or Gist for text; confirm before every upload; Slack/PR/Jira text; delete remote copies |
| PR demos | `load_pull_request`, `load_git_changes` | GitHub API (token optional for public repos); diff capped; local branches compared through GitHub (the sandbox can't run `git`) |
| What's on screen | `read_front_window`, `zoom_screen` | On-device OCR of the front window (Accessibility isn't available in the sandbox); secrets hidden and the text shown first whenever it leaves the Mac (a cloud model, or an AI agent over MCP); smooth zoom to text while recording |

Self-tests: `--s3-test <endpoint> --access … --secret …` (e.g. a local
MinIO), `--zoom-test <word>`, and `--dev-all` with `--chat` to try the tools.

## MCP: data sources and AI agents

- **Client** (`Packages/SnazzyKit/Sources/MCP/MCPClient.swift`): Streamable
  HTTP; tries the modern stateless protocol (2026-07-28: `_meta`,
  `server/discover`, `Mcp-Method`/`Mcp-Name`/`Mcp-Param-*` headers) and falls
  back to the legacy `initialize` handshake with sessions. Tools appear to the
  assistant as `mcp__<server>__<tool>`, plus `mcp_list_servers` and
  `mcp_read_resource`. Header secrets live in the Keychain. Tools that aren't
  read-only ask first (configurable per server). Results are labelled as
  external data.
- **Server** (`MCPServerCore` + `MCPHTTPServer`): serves both protocol eras;
  127.0.0.1 only, bearer token, Host and Origin checks, header/body
  validation. Off by default (Settings › MCP).
- **Plugin:** `integrations/claude-code/snazzy-pro` (Claude Code plugin with a
  skill), installable via `.claude-plugin/marketplace.json`. Other clients:
  `integrations/README.md`.
- Tested against our own server (both eras) and live against Context7 (modern)
  and DeepWiki (legacy): `SNAZZY_MCP_LIVE=1 swift test --filter MCPLiveTests`.

## Camera backgrounds

- On-device person segmentation (Vision `VNGeneratePersonSegmentationRequest`,
  balanced quality, at most 30 fps on its own queue; frames are skipped while
  it's busy, so capture never waits).
- Backgrounds: none, blur (adjustable), seven built-ins drawn in code (Spotlight,
  Ink, Studio grey, Warm studio, Ocean, Sunset, Bokeh), a solid colour, or the
  user's own images (copied into the app, at most 3840 px).
- Applied to the camera picture before crop and compositing, so previews, the
  recording preview and the recorded video match. Raw camera tracks stay
  unprocessed. Stored per camera in its profile, so presets keep it. Chat
  tools: `set_background`, `list_backgrounds`.

## Recording (phase 4)

- **Screen** comes from ScreenCaptureKit (`ScreenFeed`): a display or a window,
  30 fps, long side capped at 3840 px. Snazzy Pro's own windows are excluded
  from display capture, except the Builder's result window.
- **One clock.** Screen, camera and mic samples are all timestamped on the
  host clock, so nothing has to be lined up afterwards.
- **Lip sync** (phase 5): each camera has a delay (Sources › Crop & rotation ›
  Lip sync, or `set_inset video_delay_ms`) for a picture that runs behind the
  sound, such as an iPad by cable (150–250 ms), or negative for a Bluetooth
  mic. Frames are stamped earlier by it in recordings, the live room and live
  streams; raw `camera.mov` keeps true times and `timeline.json` the delay.
  **Calibrate with Claps** (or `calibrate_lip_sync`) measures it: clap 3 times
  in view, and the delay between each clap's sound and the hands meeting in
  the picture (by when frames arrive) is saved.
- **Composite** (`Compositor`): screen fitted into 1920×1080, inset rotated,
  cropped, scaled, rounded and bordered. The live "Preview of the recording"
  (Sources tab, or ⌥⌘P floating) uses the same code, so it shows exactly what
  is recorded.
- **Recorder:** composites at a steady 30 fps from the latest frames into
  `~/Movies/Snazzy Pro/Recordings/presentation-<timestamp>.mov` (H.264 + AAC).
  Next to it, `presentation-<timestamp> raw/` holds `screen.mov` (HEVC),
  `camera.mov` (HEVC), `mic.mov` (24-bit PCM) and `timeline.json` (pauses,
  camera freezes, inset settings), all on one timeline, so the inset can be
  changed later. No save dialogs.
- **Bigger camera on title slides** (Sources › Inset position, or `set_inset
  title_slide_size`): while a deck is presented, the camera grows on title and
  closing slides and shrinks back on the rest, easing over 0.4 s, in the
  recording, the live room and live streams. Slide markers note which slides
  were titles, so New Layout can add, change or remove it afterwards.
- **New Layout** (Recordings › New Layout…, or `relayout_recording`): make a
  recording again from its raw tracks with the camera in another corner, a
  new size, crop, rotation, background (none, blur, as recorded) or lip-sync
  delay, the camera hidden, or in 4K (HEVC). **Vertical clips** (9:16, for
  Shorts, Reels, TikTok): the screen across the top, the camera filling the
  rest. **Only part of it**: a start and end (at least 1 s), with the captions
  and chapters of that part. A live preview frame shows the result; the new
  file goes next to the original, and the original is never changed. Cancel
  any time: nothing half-made is left.
- **Robustness:** a stalled or unplugged camera never stops the screen or mic.
  The inset holds its last frame, and the freeze goes in the timeline. A silent
  or unplugged mic shows a warning and is reopened every few seconds, so sound
  comes back when it's plugged in again; the screen keeps recording meanwhile.
  A camera that failed is retried every 20 s. The inset camera can't be switched
  while recording (a preset loaded then keeps it), and a lost screen source (a
  window closed, a display unplugged) shows a warning.
- **Crash-safe:** every movie is written in 2-second fragments, so a crash,
  force quit or power cut keeps everything but the last moments. Quitting
  finishes the recording first. Recording won't start with under 1 GB free,
  and stops (and saves) itself below 500 MB.
- **Controls:** toolbar Record/Pause/Stop with timer and mic meter, the
  Record menu (⇧⌘R start/stop, ⌃⌘P pause), and the chat tools
  `start_recording`, `pause_recording`, `resume_recording` and `stop_recording`.
  Recordings are noted in the session log.

## Chat, builder and voice (phase 3)

- **Conversations** are saved as JSON in the app's Application Support folder
  and listed in the sidebar (rename/delete from the context menu). Replies
  render Markdown with copyable code blocks. User messages can be edited or
  retried: that drops the turn and everything after it, and the earlier
  history is never changed. Images and text files can be attached by
  paperclip or drag-and-drop.
- **Models from chat:** `list_models` and `set_model` let the assistant switch
  the provider/model per task (planning, writing, building, quick commands).
- **Builder agent:** tools `create_project`, `write_file`, `read_file`,
  `list_files`, `delete_file` (asks first), `check_preview` and `show_slide`
  work on projects in `Application Support/Snazzy Pro/Projects/<name>`.
  Projects are HTML/CSS/JS prototypes, or 16:9 HTML decks with a starter
  `deck.js`. The Builder tab shows the live result and the files. Code streams
  in as Claude writes it, using `eager_input_streaming` and a tolerant
  partial-JSON reader. A step log and the page console are shown too. After
  each write the agent gets console errors and a page summary back, so it can
  fix its own mistakes. Paths are confined to the project folder.
- **Voice:** the mic button (⇧⌘L) records the mic chosen in Sources and
  transcribes it on this Mac with the Speech framework (never on Apple's
  servers). The text goes into the message box, or is sent straight away if
  "auto-send" is on.
- **Voice Mode** (⌥⌘V): a hands-free conversation. Short commands ("next
  slide", "go to slide 3", "stop recording") run straight away, even with no
  AI set up. Questions for the assistant, and starting a recording, begin with
  the wake word ("Snazzy, …"), so talk in the room isn't sent to the AI or
  recorded; while recording or live, every command needs it. Replies are
  spoken with the Mac's voices, and while it speaks the mic is muted in the
  recording, the live room and streams.
- **Camera Prompter:** your speaker notes or a script in a strip right under
  the camera, scrolling at your reading speed, so you can read while looking at
  the lens. It's left out of every recording and stream, follows the slides,
  and can start and pause with the recording.
- **Session record:** with "Keep a record of each session" on (default),
  messages, tool calls, builder steps and voice clips (`.m4a`) are written with
  timestamps to `~/Movies/Snazzy Pro/Sessions/<date> <title>/session.jsonl`.

## Capture design (so far)

- **One feed per device.** `FeedManager` shares a `CameraFeed` between the
  Sources panel, floating previews and (later) the recorder. Each feed's
  `AVCaptureSession` is fully configured before it starts. Consumers read
  frames from its `FrameReceiver` instead of adding outputs to a running
  session, since that reconfigures the session and can interrupt a recording.
- **iPad/iPhone over USB.** The app opts in with
  `kCMIOHardwarePropertyAllowScreenCaptureDevices` and waits for the device to
  appear (up to ~45 s), showing progress. Only the device's video ports are
  connected. The last frame is held, because these devices send frames only
  when their screen changes.
- **Stalls.** No frames for more than 2 s shows "No new frames for Ns" and
  logs it to Diagnostics. After 5 s the feed restarts (at most every 10 s).
  Freeze intervals are recorded for the timeline. Unplugging shows
  "Disconnected" and holds the last frame; reconnecting restarts the feed.
- **Crop/rotation per device** (`DeviceProfile`, persisted). The prototype's
  iPad/iPhone defaults are used. Rotation `left` = 90° anticlockwise
  (ffmpeg `transpose=2`), verified by pixel tests. `FrameTransform` is shared
  by previews and the future compositor, so the preview is exactly the inset.
- **Previews** float, resize to the crop's aspect ratio, support
  drag-to-pan and scroll/pinch-to-zoom, and use `sharingType = .none`
  (`screencapture` cannot capture them). The recorder will also exclude
  their window numbers in its `SCContentFilter`.
- **Mic reconnects.** If the selected mic's ID disappears but a mic with the
  same name exists, it is reselected and a warning is shown.

## Security

- API keys live only in the login Keychain (service `com.snazzy.pro.api-keys`).
  They are never written to files, UserDefaults or logs.
- The app is sandboxed: network client, camera, audio input, user-selected files.
- Debug builds are ad-hoc signed. Each rebuild changes the signature, so macOS
  may ask once to allow Keychain access to the stored key.

## Licence

The core of Snazzy Pro is open source under the [Apache License 2.0](LICENSE).
The name, logo and icon are trademarks and aren't covered by it (see
[NOTICE](NOTICE) and [TRADEMARKS.md](TRADEMARKS.md)). Pro features are
proprietary and not in this repository; the plan is in
[docs/business/PRO.md](docs/business/PRO.md). Contributions: [CONTRIBUTING.md](CONTRIBUTING.md).

