# CLAUDE.md

Snazzy Pro: a macOS 15+ presentation studio driven by an AI chat assistant
(Swift 6, SwiftUI). It plans a talk, builds HTML slides or prototypes, frames the
camera, records screen + camera inset + mic, and goes live: a room on the local
Wi-Fi or RTMP(S) to YouTube, Twitch and others. There are iPhone/iPad and Apple
Watch remotes. Models can be local (Ollama, Apple on-device FoundationModels) or
cloud (Anthropic).

The repo is open core (Apache-2.0) and **public on GitHub**. Pro features are
planned for a separate private package and don't exist yet (`docs/business/PRO.md`).

User-facing docs: `README.md`. Phase plan and what's done: `ROADMAP.md`. Known
gaps and bugs per feature: `docs/ANALYSIS.md` (local file, may be absent).

## Commands

```sh
xcodegen                                   # regenerate SnazzyPro.xcodeproj; run after editing project.yml or adding/removing files
xcodebuild -scheme SnazzyPro -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/SnazzyPro.app

swift test --package-path Packages/SnazzyKit                      # all package tests (~130, a few seconds)
swift test --package-path Packages/SnazzyKit --filter RemoteTests  # one suite

# Opt-in tests that touch real resources
SNAZZY_KEYCHAIN_TESTS=1 swift test --package-path Packages/SnazzyKit
SNAZZY_MCP_LIVE=1 swift test --package-path Packages/SnazzyKit --filter MCPLiveTests
SNAZZY_RTMP_TEST=... swift test --package-path Packages/SnazzyKit --filter BroadcastTests

# Headless self-tests (DEBUG builds only, App/Sources/SelfTest.swift)
APP=build/DerivedData/Build/Products/Debug/SnazzyPro.app/Contents/MacOS/SnazzyPro
$APP --self-test                                   # Keychain + Ollama + Anthropic
$APP --self-test --chat "…" [--provider anthropic --model claude-opus-5-5] [--dev-all]
$APP --self-test --devices | --record 6 | --composite | --builder-snapshot <proj> | --mcp-server
# more: --slides-record --broadcast-test --remote-pair --live-room --live-deck
#       --share-roundtrip --s3-test --zoom-test --preset-roundtrip --builder-errors

Scripts/archive-appstore.sh [--upload]             # runs the tests, then archives a Release build for the Mac App Store
```

The other schemes are `SnazzyProiOS` and `SnazzyProWatch`. iOS signing needs
`DEVELOPMENT_TEAM` in `Config/Local.xcconfig`.

## Build gotchas

- **Never edit `SnazzyPro.xcodeproj`, `App/Info.plist`, `*.entitlements`, `iOS/Info.plist`
  or `watchOS/Info.plist` by hand.** They are generated from `project.yml` and git-ignored.
- **Warnings are errors** (`SWIFT_TREAT_WARNINGS_AS_ERRORS`). Swift 6 language mode,
  strict concurrency.
- **Signing:** `Config/Local.xcconfig` (git-ignored) holds the signing identity and team.
  The default is ad-hoc signing, so macOS re-asks for camera, mic, screen-recording and
  Keychain access after each rebuild.
- **The Xcode scheme only runs SnazzyCoreTests and AssistantTests.** Use `swift test` to
  run everything.
- **There is no app-target test target.** Code in `App/`, `iOS/` and `watchOS/` is covered
  only by the self-tests.
- **CI** (`.github/workflows/ci.yml`, `macos-26`, Xcode 26.5) runs on every PR and push to
  main:
  - the package tests and the Mac app build;
  - an unsigned build of the iPhone app with the Watch app inside.

  The other workflows handle auto-tagging on main, GitHub Pages for `site/`, and
  Cloudflare DNS plus WSL Proxy for snazzy.pro.
- **The self-tests use the real user's UserDefaults and Keychain**, and some change settings.
- **The app is sandboxed.** It can't run `git` or other subprocesses. PR demos go through
  the GitHub API instead.
- **The only third-party dependency is HaishinKit, pinned to exactly 2.2.5** (RTMP, BSD-3).
  New dependencies need approval; record them in `THIRD_PARTY_NOTICES.md`.

## Layout

| Path | What |
|---|---|
| `project.yml` | XcodeGen spec: 3 targets (`SnazzyPro` macOS, `SnazzyProiOS`, `SnazzyProWatch` embedded in iOS), Info.plist keys, entitlements |
| `App/Sources` | Mac app. `@MainActor @Observable` controllers plus SwiftUI `Views/` |
| `iOS/Sources` | iPhone/iPad remote: pairing, controls, teleprompter, chat. `WatchRelay` relays watch commands to the Mac |
| `watchOS/Sources` | Watch remote (WatchConnectivity to the iPhone only) |
| `Packages/SnazzyKit` | Local SwiftPM package, one module per area (see below). UI-free and unit-tested |
| `integrations/claude-code/snazzy-pro` | Claude Code plugin (MCP config + skill). Marketplace file: `.claude-plugin/marketplace.json` |
| `site/` | Landing page, blog, privacy and support pages (static HTML, deployed to GitHub Pages) |
| `docs/` | `brand/`, `launch/` (App Store), `business/PRO.md` (open-core plan) |

### SnazzyKit modules

| Module | Contents |
|---|---|
| `SnazzyCore` | `AppSettings`, `KeychainStore`/`SecretStore`, `JSONValue`, `Log`, `CaptureSetup`/`InsetGeometry`/`DeviceProfile`, `PresetStore`, `HTTPMessage` (hand-rolled HTTP/1.1 parser shared by the Live and MCP servers), `SigV4`, `SecretRedactor` |
| `Assistant` | `ModelProvider` protocol with `AnthropicProvider` (SSE), `OllamaProvider` (NDJSON), `AppleOnDeviceProvider` (FoundationModels). Also `ConversationRunner` (agent loop), `ToolRegistry`, `SchemaValidator`, `ConversationStore` |
| `CaptureEngine` | `DeviceCatalog`, `CameraFeed`/`FeedManager`/`FrameReceiver`, `ScreenFeed` (ScreenCaptureKit), `FrameTransform`, `Compositor`, `Recorder`, `BackgroundEffect` (Vision segmentation), `LiveEncoder` (fMP4/HLS), `RecordingEditor` (trim), `Transcription`/`Captions`/`Chapters`, `ScreenReader` (OCR) |
| `Builder` | `Workspace` (project folders with path confinement), `Templates` (starter `deck.js`), `PartialJSON`, `SampleDecks` (12 sectors), `SnazzyShare` (`.snazzy` file format) |
| `Slides` | **Empty placeholder.** Slide logic lives in `App/Sources/BuilderController.swift` and `Views/PresentView.swift` |
| `MCP` | `MCPClient`, `MCPProtocol`, `MCPServerCore`, `MCPHTTPServer` (dual-era: modern stateless 2026-07-28 and legacy `initialize`/session) |
| `Live` | `LiveServer` (NWListener HTTP: viewer page, fMP4 segments, SSE), `LiveSegments`, `LiveViewerPage` (inline HTML/JS), `BrainstormBoard` |
| `Broadcast` | `Broadcaster`: one HaishinKit RTMP pipeline per destination |
| `Remote` | `RemoteHost`/`RemoteClient`/`RemoteLink`, `RemoteProtocol` (length-prefixed JSON), `RemoteSecurity` (TLS 1.2 PSK), `WatchLink`. No SnazzyCore dependency; it builds for iOS and watchOS |

## Architecture essentials

- **The chat loop starts at `ChatSession.send`** (App/Sources/ChatSession.swift), which hands
  the work to `ConversationRunner.run`:
  1. The provider streams deltas and ends with a single `.completed(message)`.
  2. If the message has tool calls, each one is validated against its JSON schema.
  3. Tools marked `requiresConfirmation` show an NSAlert first.
  4. The tools execute and their results go back to the model.
  5. This repeats for at most 12 rounds. Two invalid rounds in a row stop and ask the user.

  History is append-only, and Anthropic thinking blocks are stored opaquely and echoed back.
  **Never edit or trim the history sent to Anthropic on the client.** On Opus 5.5 and Sonnet 5.5
  that invalidates thinking blocks, and newer accounts get a 400. Long-context relief is
  server-side instead (`context_management`, `clear_tool_uses_20250919` in
  `AnthropicMapping.requestBody`), and prompt caching is the top-level `cache_control`.
  Cache hits are logged as "Anthropic usage" in the `provider` log category. Ollama, which has
  no thinking binding, trims old tool payloads in `OllamaMapping.messages`.
  A new `ToolRegistry` is built for every send by `AppModel.makeToolRegistry(for: provider)`.
  `offMac` names who receives the results: the cloud provider, an MCP agent, or nil
  for a local model. Screen text and code are redacted and reviewed based on it.
  Tools with `external:` set get their result wrapped in `<external_data>`
  (`ToolRegistry.untrusted`).
- **Tools are registered in three places only:**
  - `App/Sources/AssistantTools.swift`: capture, recording, builder, live, broadcast, settings, presets, models.
  - `App/Sources/DeveloperTools.swift`: each tool is gated by its Settings › Developer toggle.
  - `App/Sources/MCPManager.swift`: `mcp__<server>__<tool>` plus `mcp_list_servers` and `mcp_read_resource`.

  Every built-in tool is **automatically exposed by Snazzy's own MCP server** too
  (127.0.0.1:47823, bearer token).
- **Model per task:** Planning, Writing, Building and Quick commands each have a model,
  stored in `AppSettings`. Defaults are `claude-opus-5-5` (`claude-sonnet-5-5` for quick
  commands); on first launch every task uses `apple-on-device` if Apple Intelligence is
  available. The on-device model only gets the tools listed in `AppleToolPolicy.priority`.
- **Capture is a pull model.** Receivers (`FrameReceiver`, `ScreenReceiver`) hold the
  latest frame, because iOS devices and SCStream only send frames when something changes.
  - Consumers composite at their own fixed rate: `latestImage` → `FrameTransform`
    (rotate, then crop) → `Compositor` (1920×1080).
  - Previews, the recorder, the live encoder and the broadcaster all use this same path,
    so the preview always matches the output.
  - There is one `CameraFeed` per device (reference-counted by `FeedManager`).
  - **Never add outputs to a running `AVCaptureSession`.** Subscribe with
    `receiver.addConsumer` instead.
- **Recording output.** All files go under `~/Movies/Snazzy Pro/Recordings/`:
  - `presentation-yyyyMMdd-HHmmss.mov`: the composite, H.264 + AAC.
  - The `… raw/` folder next to it, holding `screen.mov`, `camera.mov` (HEVC, unprocessed),
    `mic.mov` (PCM) and `timeline.json`.
  - `.chapters.vtt`, written from the slide markers.

  Session logs go to `~/Movies/Snazzy Pro/Sessions/`.

  Stamp composited video with `CompositeSpec.syncedVideoTime(_:hasCamera:)`, which applies
  the camera's lip-sync delay (`DeviceProfile.videoDelayMs`, positive = picture behind sound).
  Clap calibration is in `CaptureEngine/SyncCalibration.swift`.

  Create recording writers with `AVAssetWriter.crashSafeMovie(_:)` (fragmented `.mov`),
  never a plain `AVAssetWriter`. The required-reason APIs used (disk space, boot time,
  UserDefaults, file timestamps) must be declared in `App/Resources/PrivacyInfo.xcprivacy`,
  and in `iOS/Resources/PrivacyInfo.xcprivacy` for anything the iPhone app links.
- **Deck contract.** `deck.js` must keep:
  - `window.snazzyDeck = {show, count, current}`
  - `<section class="slide">` elements
  - `<aside class="notes">` for speaker notes

  The Present window, slide capture, remote, chapters and `check_preview` all depend on
  these. Projects are served over `snazzy-project://<slug>/` by `ProjectSchemeHandler`.
  - Projects imported from `.snazzy` files have `BuilderProject.shared == true`. They're served
    with a CSP that allows only their own files, so there's no internet access until the user
    clicks "Allow Internet".
  - `NavigationGuard` keeps every page on its project. External links open in the browser.
- **Remote:**
  - Discovery is Bonjour `_snazzyremote._tcp`, over TLS 1.2 PSK.
  - Pairing is a QR code holding a one-time 256-bit secret. Each device then gets its own key.
  - The TLS handshake only proves the device holds *some* accepted key. So every `hello`
    carries `RemoteSecurity.proof`: an HMAC of the device ID, keyed with the pairing secret
    or that device's own key. The host verifies it.
  - The Mac polls `status()` every 250 ms and pushes it when it changes.
  - The watch talks only to the iPhone app, which relays to the Mac.

## Storage

| Where | What |
|---|---|
| Keychain service `com.snazzy.pro.api-keys` | `anthropic`, `mcp.server.token`, `mcp.<uuid>.<header>`, `broadcast.<platform>`, `share.s3.access-key`, `share.s3.secret-key`, `github.token`, remote device keys |
| UserDefaults, keys prefixed `SnazzyPro.` | `settings.v1` (AppSettings JSON), `captureSetup.v1`, `developer.v1`, `mcpServers.v1`, `mcpServerEnabled`, `mcpServerPort`, `activePreset`, `sidePanelTab` |
| `~/Library/Application Support/Snazzy Pro/` (sandbox container) | `Conversations/<uuid>.json`, `Presets/<slug>.json`, `Projects/<slug>/` (with `.snazzy-project.json`), background images |
| Ports | Live room 8787–8790 (all interfaces); MCP server 47823 (loopback only); remote host uses a random port, advertised over Bonjour |

## Conventions

- **App controllers** are `@MainActor @Observable final class`.
- **Real-time and network types in the package** are `final class … @unchecked Sendable`.
  Each has its own serial `DispatchQueue` labelled `com.snazzy.pro.*` and/or an `NSLock`
  used with `withLock`, and exposes `@Sendable` callbacks. Get back to the main actor with
  `Task { @MainActor in … }`. AVFoundation, ScreenCaptureKit and Vision are imported with
  `@preconcurrency`.
- **Persisted structs decode tolerantly** (`decodeIfPresent … ?? default`). Every new
  field needs a default.
- **Secrets go only through `SecretStore`/Keychain.** Never put them in UserDefaults, files,
  logs, tool results or chat. Log with `Log.<category>` (os.Logger, subsystem `com.snazzy.pro`).
- **Ask before anything leaves the Mac.** Decide whether something leaves with
  `AppSettings.runsOnThisMac(kind)`, never `ProviderKind.isLocal`: Ollama can run on another
  computer. The checks are:
  - cloud-provider consent (`ChatSession`);
  - `CloudReview.confirm` for text sent to a cloud model, with `SecretRedactor` applied
    to screen text first;
  - an NSAlert before each stream, live room or upload.
- **Never modify the user's originals.** Edits write siblings
  (`RecordingEditor.sibling(of:suffix:ext:)`).
- **One code path for UI and assistant.** A UI button and the assistant tool call the same
  controller method. Tool handlers return state as `JSONValue` and throw
  `CaptureActionError`/`WorkspaceError` with a user-readable message. `ToolRegistry`
  converts errors into results the model can see.
- **Tests use swift-testing** (`@Suite`, `@Test`, `#expect`). Keep pure logic
  (mapping/parsing/geometry) in the package so it can be tested. Integration tests are
  gated behind environment variables.
- **Commits are DCO signed-off** (`git commit -s`). Never commit keys, personal paths
  or signing identities.

### Checklists

- **New assistant tool:**
  1. Add a `RegisteredTool` in `AssistantTools` (or `DeveloperTools`) using
     `AssistantTools.object(...)` or `emptySchema`, which set `additionalProperties:false`.
  2. Set `requiresConfirmation` for anything irreversible. If the result carries text from
     outside the app (audience, web page, files from others, GitHub, the screen), set
     `external:` too. Anything sensitive that could leave the Mac goes through `offMac`.
  3. If the on-device model needs it, add it to `AppleToolPolicy.priority`.
  4. Remember that it is also published over MCP, and that names starting with
     `get_`/`list_`/`check_`/`read_` are advertised as read-only.
- **New provider:**
  1. Add a `ProviderKind` case (`displayName`, `isLocal`, `keychainAccount`, `suggestedModels`).
  2. Write pure mapping and parser types and unit-test them.
  3. Implement `ModelProvider`.
  4. Wire it into `AppModel.makeProvider` and `unavailableReason`.
- **New remote command:**
  1. Add it to `RemoteCommand` and bump `RemoteProtocol.version`, because an unknown enum
     case kills the link on older peers. New `RemoteStatus` fields must be optional.
  2. Handle it in `RemoteController.run` (exhaustive switch).
  3. Add the iOS UI in `RemoteView`.
  4. Decide in `WatchLink.allows` whether the watch may send it.
  5. Keep the recording-state strings in step across the Mac, iOS and watch.
- **New project kind:** `ProjectKind`, `Templates.files`, the `create_project` enum, the
  BuilderPanel menu, the share sheet labels. **New sample deck:** add it to `SampleDeck.all`
  with notes on every slide. `BuilderTests` enforces the rules.
- **`.snazzy` format change:** bump `version` in `SnazzyShare`. API keys, conversations and
  recordings must never go into share files.
- **New capture source:** a camera type only needs discovery in
  `DeviceCatalog.refreshAVDevices`. A screen-like source also needs:
  - a `ScreenFeed.Source` case and `makeFilter`;
  - `CaptureSourceSelection`;
  - `CaptureController.screenSource`;
  - `SourcesPanel`;
  - `PresetController.summary`.
