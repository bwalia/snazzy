# Snazzy Pro

A native macOS app (Swift, SwiftUI, macOS 15+) for making video presentations,
driven by a chat assistant that can use local (Ollama) or cloud (Anthropic) models.
See `PROMPT.md` for the full spec and phase plan.

**Status: phase 4 (recording)** of the plan in `ROADMAP.md`.
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
# Record N seconds (main display + first iPad/iPhone + default mic) and inspect the files
SnazzyPro --self-test --record 6 [--pause-at 3] [--display LG] [--feed iPad]
# One frame of the composite from the live screen + camera
SnazzyPro --self-test --composite
# One chat turn with every app tool, printing the tool calls
SnazzyPro --self-test --chat "Put my iPad camera bottom-left and open a preview" [--provider anthropic --model claude-opus-5-5]
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
| ↳ `Slides` | Placeholder (phase 6) |

## Assistant design

- `ModelProvider.stream(_:)` returns deltas (text, thinking, tool-call started) and
  ends with one `.completed` event that carries the whole assistant message, so
  every provider produces the same history.
- Anthropic: Messages API over SSE, adaptive thinking with summaries, `effort`
  from settings, `eager_input_streaming` on tools, and server-side refusal
  fallbacks (`fallbacks: "default"`) on models that support them. Thinking blocks
  are stored opaquely and sent back unchanged; history is append-only.
- Ollama: `/api/chat` NDJSON with `tools`; `num_ctx` raised to 32k.
- Every tool call is validated against its JSON schema. An invalid call gets the
  error back so the model can retry once; a second invalid round stops and asks
  the user. Tools marked `requiresConfirmation` show a confirmation alert first.
- The chat header shows the task, model, local/cloud badge (it pulses while
  sending to a cloud provider), token use, and a warning when offline or when a
  key is missing.

## Recording (phase 4)

- **Screen** comes from ScreenCaptureKit (`ScreenFeed`): a display or a window,
  30 fps, long side capped at 3840 px. Snazzy Pro's own windows are excluded
  from display capture, except the Builder's result window.
- **One clock.** Screen, camera and mic samples are all timestamped on the
  host clock, so nothing has to be lined up afterwards.
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
- **Robustness:** a stalled or unplugged camera never stops the screen or mic.
  The inset holds its last frame, and the freeze goes in the timeline. A silent
  or failing mic shows a warning, and the screen keeps recording.
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
  transcribes it on-device with the Speech framework. The text goes into the
  message box, or is sent straight away if "auto-send" is on.
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
