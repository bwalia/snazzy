# Snazzy Pro roadmap

Phases are delivered and verified one at a time (see `PROMPT.md` §7 for the
original plan). Phase 3 was added on 2026-10-07; the original phases 3–6 moved
down by one.

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
4. **Recording** (built, in review): screen + mic + one camera inset, single process, composited
   file plus raw tracks, auto-named. Stall detection.
5. **Sync**: clap calibration, per-device delay, manual slider.
6. **Slides**: outline → slides → script from chat, slide recording mode,
   teleprompter.
7. **Post**: timeline, trim, captions, re-layout inset, exports.

### Phase 3 follow-ups
- Give vision-capable models a screenshot of the result after each write
  (`check_preview` already has the snapshot plumbing), so they catch visual
  problems like low-contrast chart labels.
- Session video (screen + camera of the developer) once the phase 4 recorder exists.
- Unit tests for the app-target pieces (Markdown parser, transcript rebuild)
  once there is an app test target.
