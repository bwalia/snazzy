# App Store Connect setup, step by step

How to configure Apple's side for Snazzy Pro: the Mac app first, set up so
the iPhone/iPad app and the Apple Watch app (later phases) join the same App
Store listing without redoing anything.

Allow about an hour, plus Apple's processing time. Everything here is done
in your browser and in Xcode with your Apple developer account. Nothing here
needs code changes except step 3.

---

## 0. Decide the identifiers first (they can't change after launch)

Pick a reverse-DNS prefix you control, ideally your company's domain
reversed, e.g. `com.yourcompany`. Then:

| What | Identifier | Why |
|---|---|---|
| Mac app **and** iPhone/iPad app | `com.yourcompany.snazzypro` | Using the **same** bundle ID on macOS and iOS lets one App Store record serve both (**Universal Purchase**): one listing, one price, buy once and use everywhere. |
| Apple Watch app | `com.yourcompany.snazzypro.watchkitapp` | A watch app's ID must start with its iPhone app's ID. |
| Widgets / extensions (later) | `com.yourcompany.snazzypro.<name>` | Same rule. |
| App Group (shared storage) | `group.com.yourcompany.snazzypro` | Lets the iPhone app, Watch app and extensions share presets and pairing data. |
| iCloud container (later, optional) | `iCloud.com.yourcompany.snazzypro` | Syncs presets and projects between your Mac, iPhone and iPad. |

> The app currently uses `com.snazzy.pro`. Tell me your chosen ID and I'll
> switch `project.yml` (one line) before your first upload.

Also decide:
- **Seller name.** Your legal name or company; it's shown on the App Store and can't be changed casually.
- **App name.** "Snazzy Pro". Names are unique across the store, and step 4 tells you if it's taken.
- **Price.** Free, paid, or free with in-app purchase or subscription. You can change prices later, but IAP needs extra setup.

## 1. Apple Developer Program

1. Enrol at https://developer.apple.com/programs/ ($99/year) as an
   individual or an organisation. For a company you'll need a D-U-N-S number.
2. In Xcode › Settings › Accounts, add your Apple ID and check the team appears.

## 2. Identifiers (developer.apple.com › Certificates, IDs & Profiles)

1. **Identifiers › + › App IDs › App.**
   - Description: Snazzy Pro
   - Bundle ID: **Explicit**, `com.yourcompany.snazzypro`
   - Capabilities: leave the defaults for now. App Sandbox, camera and
     microphone are entitlements in the app itself, not capabilities here.
     When the companion apps arrive, come back and enable **App Groups**
     (and **iCloud** if you want sync).
2. *(For phases 9–13, you can create these now:)*
   - **Identifiers › + › App Groups**: `group.com.yourcompany.snazzypro`.
   - **Identifiers › + › App IDs**: `com.yourcompany.snazzypro.watchkitapp` (when the Watch app starts).
3. **Certificates.** Xcode creates these automatically when you upload with
   automatic signing (our `Scripts/archive-appstore.sh` does). Otherwise create:
   - **Apple Distribution** (signs App Store builds for all platforms)
   - **Mac Installer Distribution** (signs the `.pkg` uploaded for the Mac App Store)

## 3. Point the project at your team and bundle ID

1. `Config/Local.xcconfig` (git-ignored) already holds your signing identity
   and `DEVELOPMENT_TEAM`.
2. Change `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` to your ID (or ask me to).
3. Run `xcodegen`, then build once and run the app.

## 4. Create the app record (appstoreconnect.apple.com › Apps › +)

1. **New App**
   - Platforms: tick **macOS**. Add **iOS** later to this same record, which
     gives Universal Purchase. Don't create a separate iOS app.
   - Name: Snazzy Pro
   - Primary language: English (U.K.) or English (U.S.)
   - Bundle ID: `com.yourcompany.snazzypro`
   - SKU: `snazzypro-001` (private; anything unique)
   - User access: Full access
2. **App Information**
   - Subtitle: *Presentations, just by talking*
   - Category: Primary **Photo & Video**, secondary **Productivity**
   - Content rights: "Does not contain, show, or access third-party content".
     The AI is the user's own choice and content.
   - Age rating: complete the questionnaire, answering "None" or "No" throughout. Expected rating: 4+.
3. **Pricing and Availability:** price (or Free), countries, and pre-orders if you want them.
4. **App Privacy**
   - Privacy Policy URL: https://bwalia.github.io/snazzy/privacy.html
   - Data collection: **"No, we do not collect data from this app"**. The
     reasoning is in `APP_STORE.md` §7. Revisit if you ever add analytics or
     your own servers.
5. **Agreements, Tax, and Banking** (top-right menu): accept the Paid Apps
   agreement and add bank and tax details. This is required for paid apps or IAP,
   and it's easiest to do now.

## 5. The 1.0 version page (macOS)

Copy from `APP_STORE.md` §4:

- Promotional text, description, keywords
- Support URL: https://bwalia.github.io/snazzy/support.html
- Marketing URL: https://bwalia.github.io/snazzy/
- Copyright: `2026 <your seller name>`
- Screenshots: at least 1, up to 10, in a 16:10 ratio (2880×1800 recommended). See §5 of `APP_STORE.md`.
- App Review information: your contact details, plus the notes from `APP_STORE.md` §6
  (and a temporary Anthropic key for reviewers on Macs without Apple Intelligence).
- Version release: **Manually release this version**, so you control launch day.

## 6. Upload a build and test it

```sh
Scripts/archive-appstore.sh --upload
```

1. Wait for processing (10–30 minutes) and the "ready to test" email.
2. **TestFlight › macOS:** add yourself as an internal tester, install the
   build from the TestFlight app, and run the checklist: permissions, chat
   with the on-device model, record 10 minutes, unplug the camera mid-recording,
   backgrounds, presets, builder.
3. On the version page, under **Build**, select the build.

## 7. Submit

1. Add for Review › Submit. Review usually takes 1–3 days.
2. If rejected, the Resolution Center explains why. Send it to me and I'll fix it.
3. When approved, click **Release**. Then swap the website's "Coming soon"
   button for Apple's official Mac App Store badge (marked in `site/index.html`).

---

## Later: iPhone, iPad and Apple Watch (phases 9–13)

| When | In App Store Connect | In the project |
|---|---|---|
| iPhone/iPad app ready | Same record › **+ Platform › iOS**. It shares the bundle ID, so the iOS app is part of the same purchase. Add iPhone and iPad screenshots. | New iOS target with the **same** bundle ID; shared Swift packages (SnazzyCore, Assistant) built for iOS. |
| Apple Watch app | No separate record: the Watch app ships inside the iOS app. Add Watch screenshots on the iOS version page. | watchOS target `…snazzypro.watchkitapp`, embedded in the iOS app. |
| Shared data | Enable **App Groups** (and iCloud if wanted) on each App ID. | Add the group to each target's entitlements. |

Apple Watch notes:
- The Watch app talks to the **iPhone app** (WatchConnectivity), which talks to
  the Mac. watchOS doesn't allow the general local-network access the Mac link
  needs, so the iPhone app comes first.
- Planned controls: start, pause and stop, next and previous slide, the recording
  timer, and haptic taps for "1 minute left" or "time's up".
