---
name: snazzy-pro
description: Use when the user wants to make a presentation, slide deck, app prototype or screen/camera recording with Snazzy Pro on their Mac, or to set up its microphone, camera inset, background or recording. Requires the Snazzy Pro app running with "Let AI agents use Snazzy Pro" turned on.
---

# Driving Snazzy Pro

Snazzy Pro is a Mac app that builds HTML slide decks and prototypes and records
videos (screen + camera inset + microphone). Its MCP server (`snazzy-pro`)
exposes the same actions as its built-in assistant.

1. **Start with `get_project_state`** to see the models, devices, capture setup,
   open builder project and recording status.
2. **Build:** `create_project` (kind `presentation` or `prototype`), then
   `write_file` with the **complete** file content; read `console_errors` in the
   result and fix them; `check_preview` to verify; `show_slide` to move through a deck.
   Decks are 16:9: one `<section class="slide">` per slide in `.deck`, speaker
   notes in `<aside class="notes">`.
3. **Set up:** `list_devices`, then `select_mic`, `select_capture_source`,
   `select_inset_device`, `set_inset` and `set_background` (by the names
   `list_devices` and `list_backgrounds` return). iPads and iPhones on USB can take
   up to 30 seconds to appear.
4. **Record:** `start_recording` / `pause_recording` / `resume_recording` /
   `stop_recording`. Files save to ~/Movies/Snazzy Pro/Recordings.
5. **Presets:** `list_presets`, `load_preset`, `save_preset`.

Actions that can't be undone ask the person at the Mac for confirmation; if one is
declined, say so and don't retry.

## Setup

In Snazzy Pro: Settings › MCP › turn on **Let AI agents use Snazzy Pro**, then
copy the token and run:

```sh
export SNAZZY_MCP_TOKEN=<token>        # in the shell that starts Claude Code
```

Or add it directly: `claude mcp add --transport http snazzy-pro http://127.0.0.1:47823/mcp --header "Authorization: Bearer <token>"`.
