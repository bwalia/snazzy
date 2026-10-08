# Testing the Apple Watch remote

The watch app has no network link of its own. It talks to the Snazzy Pro iPhone
app over WatchConnectivity, and the iPhone app relays to the Mac:

```
Apple Watch ──WatchConnectivity──▶ iPhone app ──encrypted Wi-Fi link──▶ Mac app
            ◀──── status ─────────            ◀──── status ────────────
```

So every test needs all three: the Mac app, the iPhone app connected to it, and
the watch app.

## 1. Unit tests (no simulators)

```sh
swift test --package-path Packages/SnazzyKit --filter "WatchLink|RemoteProtocol|RemoteTests"
```

`WatchLinkTests` covers the shared payload: status trimmed for the watch (no
notes or mic level), the timer counting on while recording, de-duplicating
status, and the watch not being allowed to send chat.

## 2. Simulators, end to end (one command)

Needs Xcode with the iOS and watchOS platforms. If watchOS is missing:
`xcodebuild -downloadPlatform watchOS` (a few GB), or Xcode › Settings › Components.

```sh
Scripts/watch-sim-test.sh          # pairing stays open for 180 s
Scripts/watch-sim-test.sh 600      # or longer, to try the controls by hand
```

What it does:

1. Builds the Mac app and the iPhone app (with the watch app inside).
2. Boots the first paired iPhone + Apple Watch simulator (`xcrun simctl list pairs`).
3. Runs the Mac app's pairing self-test (`SnazzyPro --self-test --remote-pair`).
4. Launches the iPhone app with `-debugPairURL` (Debug builds only), so it pairs
   without scanning the QR code, and waits until the Mac reports it connected.
5. Opens the watch app and saves screenshots to `build/watch-test/`.

Pass: `build/watch-test/watch.png` shows your Mac's name, **Ready**, **0:00**
and a red Record button. The self-test removes the test iPhone from the Mac's
paired devices when it ends.

Careful: Record on the watch really records on the Mac (to
`~/Movies/Snazzy Pro`), and macOS may ask for Screen Recording permission.

## 3. Simulators, by hand (full Mac app)

Use this to try slides and recording with a real deck.

1. `xcodegen`, then run the **SnazzyPro** scheme (the Mac app). Open a deck in
   the Slides tab.
2. In the Mac app: menu **Devices › iPhone & iPad Remote…** › **Pair a Device**,
   then **Copy Pairing Link** (Debug builds only; a simulator can't scan the QR code).
3. Build the **SnazzyProiOS** scheme for an iPhone simulator that has a paired
   watch, then launch it with the link (it pairs once and remembers the Mac):
   `xcrun simctl launch <iphone-udid> com.snazzy.pro -debugPairURL "<link>"`
4. Run the **SnazzyProWatch** scheme on that iPhone's paired Apple Watch
   simulator (Xcode picks the pair automatically).
5. Work through the checklist below.

## 4. Real iPhone and Apple Watch

1. Put your team in `Config/Local.xcconfig` (git-ignored), e.g.
   `DEVELOPMENT_TEAM = ABCDE12345`.
2. Run **SnazzyProiOS** on your iPhone. Xcode installs the watch app on the
   paired watch too (or turn it on in the iPhone's Watch app › Snazzy Pro).
3. Run Snazzy Pro on the Mac, same Wi-Fi as the iPhone. Pair by scanning the QR
   code in **Devices › iPhone & iPad Remote…** with the iPhone.
4. Keep the iPhone app open (it keeps the screen on while connected), then open
   Snazzy Pro on the watch.

## Checklist

| Check | Expected on the watch |
|---|---|
| iPhone app closed | "Open Snazzy Pro on your iPhone." and Try Again |
| iPhone not paired with a Mac | "Pair your iPhone with your Mac first." |
| Mac app quit while connected | A connection message from the iPhone; recovers when the Mac is back |
| Connected, idle | Mac name, **Ready**, 0:00, red Record button |
| Tap Record | Mac counts down then records; watch shows **Recording**, timer runs, wrist tap |
| Pause / Resume | Timer stops and continues; Mac matches |
| Stop | Mac saves the recording; watch shows **Ready**, wrist tap |
| Swipe up to Slides | "Slide 1 of N", the title and the next slide's title |
| Next / Previous | Mac changes slide; buttons disable at the first and last slide |
| No deck open on the Mac | "No slide deck open on the Mac." |
| Command fails (e.g. iPhone app closed mid-tap) | Orange message and a failure tap |
| Watch app reopened mid-recording | Timer shows the right time straight away |

Not built yet: "1 minute left" and "time's up" taps (they need a talk-length
setting on the Mac), and Digital Crown slide changes.
