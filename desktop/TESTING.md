# Testing Snazzy Pro on Windows and Linux

CI (`.github/workflows/desktop.yml`) runs fmt, clippy and `cargo test --workspace` on
Windows x64, Linux x64 and Linux ARM64, then builds an installer for each. What it can't
check is the app itself: the window, the OS credential store and a real model. Do that by
hand with the checklist below before merging a desktop change.

## Get a build

From a CI run (installers are kept for 14 days):

```sh
gh run list --workflow desktop.yml --limit 3
gh run download <run-id> -n snazzy-pro-Linux-X64      # or Linux-ARM64, Windows-X64
```

- **Linux:** `sudo apt install ./snazzy-pro_*.deb`, then run `snazzy-pro`.
- **Windows:** open the `.msi`. It isn't signed yet, so SmartScreen warns: More info › Run anyway.

From source (Rust 1.85+, Node 22):

```sh
# Linux only: system libraries
sudo apt install libwebkit2gtk-4.1-dev libgtk-3-dev libayatana-appindicator3-dev \
  librsvg2-dev libsoup-3.0-dev libdbus-1-dev pkg-config build-essential

cd desktop
cargo test --workspace
cd app && npm ci && npx tauri dev
```

On Windows, install Rust with the MSVC toolchain (Visual Studio C++ Build Tools). Other
folders in the repo have file names with colons, which Windows can't check out, so clone
only what the desktop app needs:

```powershell
git config --global core.protectNTFS false
git clone --filter=blob:none --sparse https://github.com/bwalia/snazzy
cd snazzy; git sparse-checkout set desktop docs/specs decks
```

No spare PC: UTM or Parallels on a Mac runs Ubuntu 24.04 ARM (use the ARM64 `.deb`) and
Windows 11 ARM (runs the x64 `.msi` under emulation).

## Checklist

Do each step on Windows and on Linux.

**Window**
- [ ] The app opens to "What are we making?" with no console errors.
- [ ] Ctrl+N starts a new conversation.

**Settings and folders**
- [ ] Choose Ollama, change the URL, Save. Quit and reopen: the choice is kept.
- [ ] The settings file is at `%APPDATA%\Snazzy Pro\desktop-chat.json` (Windows) or
      `~/.local/share/snazzy-pro/desktop-chat.json` (Linux) and holds no key.

**Credential store**
- [ ] Save an Anthropic key: "Key saved in your credential store."
- [ ] It appears under `com.snazzy.pro.api-keys` in Credential Manager (Windows) or
      Seahorse / `secret-tool search service com.snazzy.pro.api-keys` (Linux).
- [ ] Quit and reopen: Settings says "A key is saved."
- [ ] Clear the field and save: "Key removed.", and it's gone from the store.
- [ ] Linux without a keyring daemon (bare window manager): saving fails with a readable
      message, not a crash.

**Ollama (local)**
- [ ] With Ollama running, List Models shows the installed models.
- [ ] The chat says "Messages stay on this computer or your network".
- [ ] A message streams back. Stop ends it mid-reply. A follow-up remembers the first message.
- [ ] With Ollama stopped, sending shows an error, not a hang.

**Claude (cloud)**
- [ ] Switch to Claude: the chat says "Messages go to Anthropic".
- [ ] The first send asks "Send chats to Anthropic?". Not Now sends nothing.
- [ ] Send to Anthropic: the reply streams, with "Thinking…" first on thinking models.
- [ ] Quit and reopen: no second consent prompt.
- [ ] A wrong key shows Anthropic's error in the chat.

**Decks**
- [ ] Slides › Samples: Open Sample copies it into My Decks and shows it in the Builder,
      with "Slide 1 of N" under the preview. ‹ and › change slides.
- [ ] Edit Slides: change a heading and save. The preview reloads on the same slide with
      the change. Esc with unsaved changes asks first.
- [ ] New Deck makes a three-slide starter and opens the editor.
- [ ] My Decks groups decks by category; a tag filters them. Details changes both.
- [ ] Ctrl+Shift+F jumps to search. A word from a sample you haven't opened finds it;
      clicking the result opens that sample at that slide.
- [ ] Slides › Present: slide list, speaker notes (A− / A+), next slide, timer.
- [ ] Open Present Window "In a window": the deck alone; Next in the main window moves
      both; arrow keys in the Present window move both; F toggles full screen, Esc leaves it.
- [ ] With a second display: Present Window goes full screen on it.
- [ ] Share saves `<deck>.snazzy` in Downloads. Open .snazzy adds it back as a new deck with
      the "no internet" banner; Allow Internet asks first and removes the banner.
- [ ] Double-clicking a `.snazzy` file (installed app) opens Snazzy Pro and asks before adding it.
- [ ] Get Decks lists Snazzy Pro's decks from GitHub; Add to My Decks downloads and opens
      one, filed under its category with the "no internet" banner. Adding a repo by
      `owner/repo` lists its decks; a bad name gives a readable message.
- [ ] A web link in a deck opens in the browser, not inside the app.
- [ ] Delete asks first, then the deck is gone from My Decks and the disk.
