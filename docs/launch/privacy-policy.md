<!-- Published version: site/privacy.html -->
# Snazzy Pro privacy policy

*Last updated: 7 October 2026*

Snazzy Pro is a Mac app for planning, building and recording presentations.
This policy explains what happens to your information.

## The short version

- We (the makers of Snazzy Pro) **don't collect any data**: no analytics, no
  tracking, no accounts and no servers.
- Your recordings, projects, conversations, settings and session records stay
  **on your Mac**.
- If you choose a **cloud AI provider** (such as Anthropic), the content you
  send to the assistant goes **directly from your Mac to that provider**, using
  your own API key, and only after you agree.

## What stays on your Mac

- Screen, camera and microphone recordings, in `Movies/Snazzy Pro/Recordings`.
- Session records (messages, assistant steps and voice clips), in
  `Movies/Snazzy Pro/Sessions`. You can switch these off.
- Conversations, builder projects, presets and settings, in the app's own
  container in your Library folder.
- API keys, in the macOS Keychain.

Voice input is transcribed by Apple's Speech framework, on your Mac where your
language supports it.

## Cloud AI providers

When you pick a cloud model, Snazzy Pro sends that provider your messages, any
files or images you attach, and what the assistant's tools return (for example
device names, your settings, and the files of projects it builds). Recordings,
camera and screen video are never sent. The provider processes this under its
own terms and privacy policy, for example Anthropic's at
https://www.anthropic.com/legal/privacy. You can use a local model (Ollama)
instead to keep everything on your Mac, and you can withdraw consent in
Settings › Chat & Voice.

## Live rooms, live streams and sharing

- **Live room (Live tab).** Your live picture (slides or screen with your camera
  inset), your microphone and the brainstorm board go directly from your Mac to
  browsers on your local network that have the room code. Nothing passes
  through any server of ours or the internet. Ideas people post are kept in
  memory only while the room is open, plus anything you then ask the assistant
  to do with them.
- **Going live online.** If you choose Go Live, your live picture and
  microphone are sent to the service you pick (YouTube, Twitch, Vimeo, Facebook
  or your own server) using your stream key, which is stored in your Mac's
  Keychain. That service handles the stream under its own terms. Snazzy Pro
  asks before every stream.
- **Sharing (.snazzy files).** You choose what goes in the file and who you
  send it to. Snazzy Pro doesn't send it anywhere itself.

## Permissions

Snazzy Pro asks for camera, microphone, screen recording, speech recognition
and local network access only to provide the features you use. You can change
these at any time in System Settings › Privacy & Security.

## Children

Snazzy Pro isn't directed at children and doesn't knowingly process
children's data.

## Contact

Open an issue at https://github.com/bwalia/snazzy/issues. We'll update this page if anything changes.
