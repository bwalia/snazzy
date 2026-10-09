# Mac App Store launch

Status and everything needed to submit Snazzy Pro to the Mac App Store.

## 1. Already done in the app

| Requirement | How |
|---|---|
| App icon (Dock, Finder, App Store) | `App/Resources/Assets.xcassets/AppIcon.appiconset`, 16–1024 px, from `docs/brand/logo-icon*.svg` |
| App Sandbox + Hardened Runtime | `project.yml` entitlements: camera, microphone, network client, user-selected files, Movies folder |
| Usage descriptions | Camera, microphone, speech recognition, local network (`project.yml` → Info.plist) |
| Privacy manifest | `App/Resources/PrivacyInfo.xcprivacy`: no tracking, no collected data; required-reason APIs: UserDefaults (CA92.1), system boot time (35F9.1) |
| Third-party AI consent (guideline 5.1.2) | A one-time prompt per cloud provider before anything is sent, explaining what is shared; can be withdrawn in Settings › Chat & Voice. Local models never ask. |
| No private API | The Builder serves projects over `snazzy-project://` (WKURLSchemeHandler) instead of private WebKit preferences |
| Export compliance | `ITSAppUsesNonExemptEncryption = NO` (HTTPS only) |
| No save dialogs, auto-named output | Recordings and session records go to `~/Movies/Snazzy Pro/` (Movies entitlement) |
| Debug-only code removed from Release | The self-test is `#if DEBUG` |
| Archive and upload | `Scripts/archive-appstore.sh` (export) / `--upload` |

## 2. Decisions and actions only you can do

1. **Bundle ID.** It's currently `com.snazzy.pro`. Once an app ships, this
   can't change. Use a reverse-DNS ID you own (e.g. `com.<yourcompany>.snazzypro`)
   and tell me, and I'll update `project.yml`.
2. **Seller name and copyright.** App Store Connect shows your legal or company
   name as the seller. Set the copyright line (`NSHumanReadableCopyright` in
   `project.yml`, currently "© 2026 Snazzy Pro").
3. **Name check.** Make sure "Snazzy Pro" is available in App Store Connect
   (names are unique across the store) and doesn't clash with a trademark.
4. **Developer account.** Apple Developer Program membership ($99/year). In
   Xcode › Settings › Accounts, sign in with the team that owns the app.
5. **App Store Connect record.** My Apps › + › New App: platform macOS, name,
   primary language English (UK or US), the bundle ID from step 1, SKU (e.g.
   `snazzypro-mac-001`).
6. **Privacy policy and support URLs** (both required). They're live on the
   landing site (`site/`, deployed to GitHub Pages):
   - Marketing URL: https://www.snazzy.pro/
   - Privacy policy URL: https://www.snazzy.pro/privacy.html
   - Support URL: https://www.snazzy.pro/support.html
7. **Pricing.** Free, paid, or free with in-app purchase or subscription (IAP
   needs extra work). Plus availability countries.
8. **Upload:** `Scripts/archive-appstore.sh --upload`, then test via
   TestFlight (macOS) before submitting.

## 3. Strongly recommended before submitting

- **Works with no setup** ✅: on a Mac with Apple Intelligence on (macOS 26+),
  the app uses Apple's on-device model for every task on first launch, so chat,
  device setup, recording and presets work with no key and no network. For
  reviewers on Macs without Apple Intelligence, still include a temporary
  Anthropic key in the review notes and revoke it after review.
- **Lip-sync calibration (phase 5)** before marketing it for camera-inset videos.
- **Screenshots** from a clean demo session (no personal windows). See section 5.

## 4. Store listing (character limits checked)

**Name** (30): Snazzy Pro

**Subtitle** (30): Presentations, just by talking

**Promotional text** (170, can change any time):
Plan a talk, build the slides or a clickable prototype, frame your camera and record a polished video, all by chatting. Local or cloud AI, your choice.

**Keywords** (100):
presentation,slides,screen recorder,video,teleprompter,webcam,picture in picture,AI,record,demo,deck

**Primary category:** Photo & Video · **Secondary:** Productivity

**Description:**

> Snazzy Pro is a presentation studio you run by talking.
>
> Tell it what you need ("a 5-minute update on our Q3 results for the
> leadership team") and it plans the talk, builds the slides and writes your
> script. Ask for a clickable prototype and watch it being built, live, with a
> working preview you can present.
>
> Then record. Snazzy Pro captures your screen or slides, your microphone and a
> camera inset together, in one place, perfectly in step. Use your Mac's
> camera, a USB webcam, Continuity Camera, or your iPad or iPhone connected by
> cable, and frame it with live previews that never show up in the recording.
>
> AI YOUR WAY
> • Use a model on your Mac with Ollama: nothing leaves your computer.
> • Or use Claude from Anthropic with your own API key: you're asked before
>   anything is sent.
> • Switch models per task, and save your setups as presets.
>
> BUILD
> • HTML slide decks and app prototypes, written and checked live.
> • Errors are caught and fixed by the assistant before you see them.
>
> RECORD
> • Screen, window or slides, plus camera inset and mic, in one take.
> • Pause and resume, automatic naming, no save dialogs.
> • Raw screen, camera and mic tracks are kept, so you can change the layout later.
> • If a camera freezes or is unplugged, the recording carries on.
>
> TALK
> • Push-to-talk voice input, transcribed on your Mac.
> • A timestamped record of each session, if you want one.

**What's New (1.0):** First release.

**Age rating:** 4+ (no objectionable content). Answer "No" to all content
questions. The app has unrestricted web access only through the user's own AI
and preview content: answer "No" to "Unrestricted Web Access", because it's not
a browser.

## 5. Screenshots

Mac requires at least one 16:10 screenshot. Use **2880×1800** (or 2560×1600 or
1440×900). Up to 10. Suggested set:

1. Chat + Builder: a deck being built, with live code and preview ("Just say it.")
2. Sources & Preview: camera framed with crop handles, recording preview
3. Recording in progress with the toolbar timer and inset
4. A finished prototype in the Builder
5. Settings: local vs cloud models, presets

Use a clean user account or demo content (no personal windows, names or faces
you don't want public). Add a short headline above each in Manrope ExtraBold on
the Ink background (`docs/brand/BRAND.md`).

## 6. App Review notes (paste into App Store Connect)

> Snazzy Pro is a presentation and recording studio controlled by chat.
>
> To try the assistant, use the review API key below: Settings › Providers ›
> Anthropic › API key, then pick a Claude model in the chat header. (Or, on a
> Mac with Ollama installed, choose an Ollama model.) Before the first message
> to Anthropic, the app asks for consent.
>
> Review API key: <ADD A TEMPORARY KEY>
>
> Recording: Sources & Preview tab › allow Screen Recording when asked ›
> choose a display › Record (toolbar). Files save to Movies/Snazzy Pro/Recordings.
>
> Camera inset: any built-in or USB camera works. iPad/iPhone over USB is optional.
>
> The app collects no data. Content goes to Anthropic only when the user chooses
> a Claude model and agrees to the prompt.

## 7. App privacy answers (App Store Connect › App Privacy)

- **Do you or your third-party partners collect data from this app?** No.
  Snazzy Pro has no analytics, no accounts and no servers. When the user
  chooses a cloud AI provider, content is sent from their Mac directly to that
  provider with the user's own API key, at their request and after consent.
  That's user-initiated processing, not collection by you. If you add
  analytics, crash reporting with personal data, or your own servers, revisit
  this answer.
- **Tracking:** No.
