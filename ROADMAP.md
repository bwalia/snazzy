# Snazzy Pro roadmap

Phases are delivered and verified one at a time (see `PROMPT.md` §7 for the
original plan). Phase 3 was added on 2026-10-07; the original phases 3–6 moved
down by one. Phases 8–13 were added on 2026-10-07: the Mac App Store launch,
then a companion iPhone/iPad app and an Apple Watch remote. The companion app is a scope change: the
original spec listed an iOS/iPadOS app as out of scope.

1. **Skeleton** ✅: XcodeGen project, app launches, settings with Keychain-stored
   keys, streaming chat against Ollama and Anthropic, tool calling.
2. **Devices & preview** ✅: list mics/cameras/iOS devices/displays/windows;
   live floating previews with per-device crop/rotation; tools to drive them from chat.
3. **Builder agent & voice chat** ✅
   - A coding agent inside the app that builds presentations and app
     prototypes on the fly, using the configured models (local or cloud).
   - Shows on screen what it is building (files, steps, live progress) and the
     running result (live preview of the prototype / slides).
   - Speech-to-text (on-device) so the user can talk to the assistant; the
     transcript goes into the chat.
   - The developer's session with the agent (screen, camera, voice) can be
     recorded.
   - A fully functional chat system: conversations persisted, multiple
     conversations, attachments, copy/retry/edit, agents and LLMs configurable
     from chat.
4. **Recording** ✅ (screen preview, recorder, raw tracks; presets added): screen + mic + one camera inset, single process, composited
   file plus raw tracks, auto-named. Stall detection.
5. **Sync**: clap calibration, per-device delay, manual slider.
6. **Slides**: outline → slides → script from chat, slide recording mode,
   teleprompter.
7. **Post**: timeline, trim, captions, re-layout inset, exports.

8. **Mac App Store launch** (in progress, see `docs/launch/APP_STORE.md`):
   - Done: brand and app icon (`docs/brand/`, Liquid Glass layers in
     `docs/brand/icon-layers/`), landing site with privacy and support pages
     (`site/`, GitHub Pages), privacy manifest, third-party AI
     consent prompt (guideline 5.1.2), no private API (Builder serves projects
     over `snazzy-project://`), export-compliance and local-network keys, self-test
     compiled out of Release, archive/upload script (`Scripts/archive-appstore.sh`).
   - Done: Apple on-device model provider (FoundationModels): no key, no
     network; default on first launch when Apple Intelligence is on.
   - Done: camera backgrounds: on-device person segmentation with blur, seven
     built-ins, the user's own images and colours; per camera, in presets and from chat.
   - Done: MCP both ways. As a client, it connects to MCP servers (docs,
     drives, databases, RAG) over Streamable HTTP, modern 2026-07-28 with
     legacy fallback, and offers their tools and resources to the assistant.
     As a server, it exposes its own tools on 127.0.0.1 with a token for AI
     agents, packaged as a Claude Code plugin (`integrations/`).
   - Setup guide for Apple's side: `docs/launch/APP_STORE_CONNECT_SETUP.md`.
   - To do: App Store
     screenshots; App Store Connect record; TestFlight round; swap the site's
     "Coming soon" button for Apple's official Mac App Store badge.

### Next up, before phase 9

**Sharing between Snazzy Pro users** ✅:
- A `.snazzy` share file holding a Builder project (deck or prototype), and
  optionally presets and background images. API keys, conversations and
  recordings are never included.
- A Share button (AirDrop, Messages, Mail via the macOS share menu) and Export…;
  double-click or drag a `.snazzy` file in to import it into the Builder.
- The assistant can export and import too ("send this deck to Sam").

**Live classroom** (about 4–6 weeks in stages, after sharing):
- *Live room on the local network* (first): students scan a QR code and join in
  any browser, with no app or account. The Mac serves the live composite (screen,
  slides, camera inset) with about 1–2 s delay, and a brainstorm board where
  everyone adds sticky notes and votes. The host moderates; afterwards the
  assistant groups the ideas and turns them into a slide deck. Nothing leaves
  the network. About 30–50 viewers.
- *Snazzy Pro Camera* for Zoom, Teams and Meet: a camera extension (CMIO) so
  any video-call app shows your slides with your camera inset. Allowed on the
  Mac App Store.
- *Go live to YouTube, Twitch or Vimeo*: an RTMP(S) push using the platform's
  stream key (stored in the Keychain). Needs a third-party streaming package;
  confirm the package choice before adding it.
- *Hosted rooms* (later, paid Pro): join from anywhere with a link, with live
  video and the board over the internet. Needs servers, accounts and a clear
  privacy policy, because data leaves the Mac; off by default, with consent.
- The phase 9 iPhone/iPad app joins live rooms as a viewer or co-host.

### Companion iPhone/iPad app (phases 9–12, about 2–3 months)

Why: recording the device's own camera and mic on the device beats today's
USB screen mirroring. You get the real 4K camera, no Camera-app buttons to crop
out, and no mirroring delay or stalls. The device can also be a remote control
and a teleprompter. The phase 4 raw-track + timeline design already supports
re-compositing from device files.

9. **Remote control** (2–3 weeks):
   - Move SnazzyCore, Assistant and Builder into packages that build for macOS and iOS.
   - Discovery and pairing over the local network (Bonjour), confirmed with a
     pairing code or QR code; an encrypted channel.
   - Controls: start, pause and stop recording, next and previous slide, status and warnings.
   - Teleprompter on the iPad, and voice chat with the assistant from the device.
10. **Device capture** (3–5 weeks):
   - Record the device camera (up to 4K) and mic locally on the device.
   - A low-latency compressed live preview streamed to the Mac (feeds the
     composite preview like any other camera).
   - After stopping, transfer the full-quality file to the Mac, resumable and
     verified with checksums.
11. **Clock sync and Mac integration** (1–2 weeks):
   - A network time handshake between Mac and device (NTP-style, repeated during
     recording), with clap calibration (phase 5) as a check.
   - The Mac builds the final video from the device file (re-composite, re-layout, lip sync).
12. **Device hardening and release** (about 1 week):
   - Permissions; keep the screen awake while recording (the camera stops if the
     app goes to the background or the device locks); battery and heat warnings;
     Wi-Fi quality warnings (they affect the preview, not the final file).
   - TestFlight, then App Store (iOS/iPadOS).

13. **Apple Watch remote** (about 1–2 weeks, after phase 12):
   - Ships inside the iPhone app (no separate App Store record); talks to the
     iPhone app with WatchConnectivity, and the iPhone app relays to the Mac.
   - Start, pause and stop, next and previous slide, recording timer and status.
   - Haptic cues for "1 minute left" and "time's up".
   - Bundle ID `<prefix>.snazzypro.watchkitapp`; App Group shared with the iPhone app.

All platforms share one App Store record (Universal Purchase), so the Mac,
iPhone and iPad apps use the same bundle ID. See
`docs/launch/APP_STORE_CONNECT_SETUP.md`.

Already available meanwhile: Continuity Camera gives the Mac an iPhone's camera
and mic wirelessly, and Snazzy Pro lists it as a camera. It covers the iPhone
camera case today, but not remote control, iPad, or full-quality local recording.

### Phase 3 follow-ups
- Give vision-capable models a screenshot of the result after each write
  (`check_preview` already has the snapshot plumbing), so they catch visual
  problems like low-contrast chart labels.
- Session video (screen + camera of the developer) once the phase 4 recorder exists.
- Unit tests for the app-target pieces (Markdown parser, transcript rebuild)
  once there is an app test target.
