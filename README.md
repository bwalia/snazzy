# Snazzy Pro

A native macOS app (Swift, SwiftUI, macOS 15+) for making video presentations,
driven by a chat assistant that can use local (Ollama) or cloud (Anthropic) models.
See `PROMPT.md` for the full spec and phase plan.

**Status: phase 1 (skeleton).** XcodeGen project, settings with Keychain-stored
keys, and streaming chat with tool calling against Ollama and Anthropic.

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
| ↳ `CaptureEngine`, `Slides` | Placeholders for phases 2–6 |

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

## Security

- API keys live only in the login Keychain (service `com.snazzy.pro.api-keys`).
  They are never written to files, UserDefaults or logs.
- The app is sandboxed: network client, camera, audio input, user-selected files.
- Debug builds are ad-hoc signed. Each rebuild changes the signature, so macOS
  may ask once to allow Keychain access to the stored key.
