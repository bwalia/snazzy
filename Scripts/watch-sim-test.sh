#!/bin/zsh
# End-to-end test of the Apple Watch remote in the simulators:
# Mac app (pairing self-test) → iPhone simulator → Apple Watch simulator.
#
#   Scripts/watch-sim-test.sh [seconds]
#
# Needs Xcode with the iOS and watchOS platforms (Xcode › Settings › Components,
# or `xcodebuild -downloadPlatform watchOS`) and a paired iPhone + Apple Watch
# simulator (Xcode creates these; see `xcrun simctl list pairs`).
# Screenshots go to build/watch-test/. The Mac self-test removes the test
# iPhone from its paired devices when it ends.
set -euo pipefail
cd "$(dirname "$0")/.."

SECONDS_OPEN=${1:-180}
OUT=build/watch-test
mkdir -p "$OUT"

# The first available iPhone + Apple Watch simulator pair.
PAIR=$(xcrun simctl list pairs --json | python3 -c '
import json, sys
pairs = json.load(sys.stdin)["pairs"]
for p in pairs.values():
    w, ph = p.get("watch", {}), p.get("phone", {})
    if w.get("udid") and ph.get("udid"):
        print(ph["udid"], w["udid"]); break
')
[[ -n "$PAIR" ]] || { echo "No iPhone + Apple Watch simulator pair. Create one in Xcode › Window › Devices and Simulators."; exit 1; }
PHONE=${PAIR% *}
WATCH=${PAIR#* }
echo "iPhone simulator $PHONE, Apple Watch simulator $WATCH"

echo "Building…"
xcodegen -q
xcodebuild -project SnazzyPro.xcodeproj -scheme SnazzyPro -derivedDataPath build/DerivedData build -quiet
xcodebuild -project SnazzyPro.xcodeproj -scheme SnazzyProiOS -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build -quiet
IOS_APP=build/DerivedData/Build/Products/Debug-iphonesimulator/SnazzyPro.app

echo "Booting simulators…"
xcrun simctl boot "$PHONE" 2>/dev/null || true
xcrun simctl boot "$WATCH" 2>/dev/null || true
xcrun simctl bootstatus "$PHONE" >/dev/null
xcrun simctl bootstatus "$WATCH" >/dev/null
open -a Simulator

xcrun simctl install "$PHONE" "$IOS_APP"
xcrun simctl install "$WATCH" "$IOS_APP/Watch/SnazzyProWatch.app"

echo "Opening pairing on the Mac for ${SECONDS_OPEN}s…"
LOG="$OUT/mac.log"
build/DerivedData/Build/Products/Debug/SnazzyPro.app/Contents/MacOS/SnazzyPro --self-test --remote-pair --seconds "$SECONDS_OPEN" >"$LOG" 2>&1 &
MAC=$!
for _ in {1..30}; do grep -q '^PAIR ' "$LOG" && break; sleep 1; done
URL=$(grep '^PAIR ' "$LOG" | cut -d' ' -f2)
[[ -n "$URL" && "$URL" != none ]] || { echo "The Mac didn't open pairing:"; cat "$LOG"; kill $MAC 2>/dev/null; exit 1; }

# Debug builds pair from this launch argument instead of a scanned QR code.
xcrun simctl launch --terminate-running-process "$PHONE" com.snazzy.pro -debugPairURL "$URL" >/dev/null
for _ in {1..30}; do grep -q 'connected=\["' "$LOG" && break; sleep 1; done
grep -q 'connected=\["' "$LOG" || { echo "The iPhone didn't connect to the Mac:"; cat "$LOG"; kill $MAC 2>/dev/null; exit 1; }
echo "iPhone connected to the Mac."

xcrun simctl launch --terminate-running-process "$WATCH" com.snazzy.pro.watchkitapp >/dev/null
sleep 8
xcrun simctl io "$PHONE" screenshot "$OUT/iphone.png" >/dev/null 2>&1
xcrun simctl io "$WATCH" screenshot "$OUT/watch.png" >/dev/null 2>&1
echo "Screenshots: $OUT/iphone.png, $OUT/watch.png"
echo "The watch should show Ready, 0:00 and a red Record button. Try the controls in the Simulator window;"
echo "the Mac self-test keeps running for ${SECONDS_OPEN}s (log: $LOG)."
wait $MAC || true
