# Settings and presets

Source of truth: `Packages/SnazzyKit/Sources/SnazzyCore/AppSettings.swift`,
`Presets.swift` (`SettingsPreset`, `PresetStore`), `CaptureSetup.swift`.
Fixtures: `settings.json` (defaults, partial inputs → decoded, invalid inputs,
"runs on this computer"), `preset.json`, `preset-cases.json`.
Rust: `snazzy_core::settings`.

## `AppSettings`

No secrets: API keys are only in the credential store.

| Key | Default |
|---|---|
| `planning`, `writing`, `building` | `{"provider":"anthropic","model":"claude-opus-5-5"}` |
| `quickCommands` | `{"provider":"anthropic","model":"claude-sonnet-5-5"}` |
| `activeTask` | `planning` (`planning`, `writing`, `building`, `quickCommands`) |
| `anthropicBaseURL` | `https://api.anthropic.com` |
| `anthropicEffort` | `medium` |
| `ollamaBaseURL` | `http://localhost:11434` |
| `maxOutputTokens` | `32000` |
| `voiceAutoSend` | `false` |
| `recordSessions` | `true` |
| `chatTextSize` | `14`, clamped to 11…24 |
| `speakReplies` | `true` |
| `wakeWord` | `Snazzy` |
| `alwaysNeedWakeWord` | `false` |
| `voiceIdentifier` | `""` |
| `speechRate` | `0.5`, clamped to 0.1…0.9 |
| `cloudConsent` | `[]` |

`provider` is `appleOnDevice`, `anthropic` or `ollama`. Windows and Linux keep
`appleOnDevice` selections they read but can't run them.

**Tolerant reading**: every key may be missing (or `null`) and gets its default;
unknown keys are ignored. A key with the wrong type, an unknown provider or task,
or a non-object fails, as on the Mac (which then uses the defaults). **Every new
field needs a default.**

"Does this leave the computer" is decided from the configured Ollama host, never
from the provider type: only `localhost`, `127.0.0.1` and `::1` (any case) count
as this computer.

## Presets

`SettingsPreset`, saved one per file as `<file name>.json`, pretty-printed,
sorted keys, `\/`, ISO dates:

`name`, `notes`, `created`, `updated` (required); `capture` (`CaptureSetup`:
mic, source, inset device, layout, per-device profiles, title-slide size) and
`app` (`AppSettings`), both optional. Rust keeps `capture` as JSON so a preset
from a Mac round-trips unchanged. Presets also travel in `.snazzy` files
(share.md), which is why tolerant reading matters.

File name: lower-case, every character that isn't a letter or digit becomes `-`,
runs of `-` collapse and the ends are trimmed, at most 80 characters, `preset`
when empty, then `.json`. Names with the same file name are the same preset.
