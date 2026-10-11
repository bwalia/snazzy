# Windows and Linux: plan

Status: **planned, not started** (decided 2026-10-11). Nothing here is built yet.

## Decision

- **One Rust codebase for Windows and Linux**, as a separate app from the Mac app.
- **Recording and streaming:** GStreamer (LGPL), using the hardware encoders.
- **UI:** Tauri, the system web view with an HTML/JS interface. Slint is the fallback if a web UI proves limiting.
- **The Mac app stays Swift.** It isn't ported: the native app is better on macOS.
- **The two apps stay compatible through shared formats and protocols, not shared code.**

Quality of recording and streaming is the priority, which is why GStreamer
(the same kind of pipeline OBS uses) is the core rather than a browser-only stack.

## Why not reuse the Swift code

Only the pure logic in SnazzyKit would carry over:

- the provider mappings and agent loop;
- MCP;
- deck search;
- the `.snazzy` format.

The heavy parts are Apple-only:

- SwiftUI;
- AVFoundation, ScreenCaptureKit and Vision (`CaptureEngine`);
- WKWebView;
- FoundationModels;
- Keychain and StoreKit;
- the Network framework (Live, Remote).

Swift on Windows and Linux has an immature UI story and would still need
GStreamer, so the reuse isn't worth it.

## Options considered

| Option | Verdict |
|---|---|
| **Rust + Tauri + GStreamer** | **Chosen.** One codebase, LGPL media stack, slides run as-is in the web view. |
| C++ + Qt + GStreamer | Equal quality. The alternative if we'd rather write C++. Qt is free under LGPLv3 if linked dynamically. |
| C++ + Qt + libobs | Best-proven capture/streaming, but **libobs is GPL-2.0-or-later**: the whole app would become GPL and the closed Pro package (`docs/business/PRO.md`) couldn't link into it. Use OBS's source as a reference design only. |
| Electron (TypeScript) | Fastest first version, but heavy. Compositing and encoding would still need FFmpeg/GStreamer native modules. |
| C# (.NET + Avalonia) | Excellent on Windows, weaker on Linux, patchy audio/video support. |
| Swift on Windows/Linux | Little reuse (see above); immature UI bindings. |

## One codebase, thin platform layer

About 85–90% of the code is shared. Platform differences are selected with
`#[cfg(target_os = ...)]`, mostly as GStreamer element names and settings.

**Shared:**

- chat and the agent loop, with the Anthropic and Ollama clients;
- tools and the MCP server (loopback, bearer token);
- the deck library, workspace and `.snazzy` files;
- the Live room server and the remote protocol;
- compositing, recording and RTMP;
- the UI;
- secrets, through the `keyring` crate.

**Per platform:**

| | Windows | Linux |
|---|---|---|
| Screen capture | Windows Graphics Capture (`d3d11screencapturesrc`) | PipeWire portal (`pipewiresrc`), required on Wayland |
| Camera / mic | Media Foundation / WASAPI | V4L2 / PipeWire or PulseAudio |
| Hardware encoder | NVENC, AMF, QSV | NVENC, VA-API |
| Web view (slides, UI) | WebView2 | WebKitGTK |
| Secrets | Credential Manager | Secret Service |
| Packaging | MSI/MSIX, code-signed | AppImage, Flatpak or .deb |

**Libraries:**

- `gstreamer-rs`;
- `tauri`;
- `tokio` and `hyper` for the Live and MCP servers;
- `mdns-sd` for Bonjour `_snazzyremote._tcp`;
- `keyring`;
- `openssl` for the remote's TLS 1.2 PSK (`rustls` has no external PSK);
- ONNX Runtime for background segmentation, replacing Vision.

**Models:** Ollama and Anthropic as on the Mac. Apple's on-device model has no
equivalent; Ollama fills that role.

## Licensing and costs

- **Licences:** use GStreamer and FFmpeg in LGPL builds, without GPL plugins such as x264. Hardware encoders avoid needing x264.
- **Third-party notices:** record every new dependency in `THIRD_PARTY_NOTICES.md`. New dependencies need approval (see CLAUDE.md).
- **Compiling:** no paid licence is required. CI builds on GitHub Actions Windows and Linux runners, which are free for public repos.
- **Local Windows work:** use a Windows 11 VM (ARM in Parallels/UTM on Apple Silicon) or a PC. Microsoft's terms expect a Windows licence.
- **Compiler:** Visual Studio Community or Build Tools are free for individuals and open source.
- **Windows code signing:** needed for distribution, or SmartScreen warns users. Azure Trusted Signing costs about $10 a month.
- **Linux:** no signing cost.
- **Get the GPL/LGPL position checked by a lawyer** before committing to a stack.

## Compatibility with the Mac app and remotes

Write these down as specs with test fixtures that both codebases test against:

- **Remote protocol:**
  - length-prefixed JSON and `RemoteProtocol.version`;
  - TLS 1.2 PSK;
  - the `hello` HMAC proof (`RemoteSecurity.proof`);
  - QR pairing;
  - Bonjour discovery.

  With this in place, the existing iPhone, iPad and Watch remotes work with Windows/Linux unchanged.
- **`.snazzy` share files** (`SnazzyShare`, versioned).
- **`timeline.json` and the `raw/` folder,** so New Layout works on recordings from any platform.
- **The deck contract:**
  - `window.snazzyDeck = {show, count, current}`;
  - `<section class="slide">`;
  - `<aside class="notes">`.

## Order of work

1. Specs and fixtures for the formats and protocols above (in this repo).
2. Rust/Tauri skeleton with CI on Windows and Linux.
3. Slides: deck library and the Present window.
4. Chat with Ollama and Anthropic, tools and the MCP server.
5. Recording: screen, camera inset and mic, plus `raw/` and `timeline.json`.
6. Live room and RTMP streaming.
7. Remote host (pairing, TLS-PSK, Bonjour).
8. Packaging and signing.

Windows first, then Linux.

## Risks

- **Linux variety:** GNOME vs KDE, Wayland vs X11, and GPU drivers. Screen sharing on Wayland needs the portal, and the user picks the screen. Flatpak helps.
- **Web view differences:** WebView2 vs WebKitGTK render decks slightly differently, so test decks on both.
- **Hardware encoders:** availability varies by GPU. Fall back to a software encoder that keeps the licence LGPL (e.g. OpenH264).
- **Keeping two apps in step:** mitigated by the shared specs and fixtures.
