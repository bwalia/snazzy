#!/bin/bash
# Builds Snazzy Pro for direct download: a universal (Apple Silicon + Intel)
# app, signed with Developer ID, notarized by Apple and stapled, in a DMG.
#
#   Scripts/release-dmg.sh            # build/SnazzyPro-<version>.dmg
#   Scripts/release-dmg.sh --publish  # …and publish it as the website download
#
# --publish puts it on the GitHub release "mac-beta" (created if missing) as
# SnazzyPro.dmg, so the website's link never changes:
#   https://github.com/bwalia/snazzy/releases/download/mac-beta/SnazzyPro.dmg
#
# One-time setup (see docs/launch/DIRECT_DOWNLOAD.md):
#   1. A "Developer ID Application" certificate in your keychain
#      (Xcode › Settings › Accounts › Manage Certificates › + › Developer ID Application).
#   2. Notarization credentials saved in the keychain under the profile name
#      "snazzy-notary":
#        xcrun notarytool store-credentials snazzy-notary \
#          --apple-id <your Apple ID> --team-id <team ID> --password <app-specific password>
#   3. DEVELOPMENT_TEAM in Config/Local.xcconfig.
set -euo pipefail
cd "$(dirname "$0")/.."

PUBLISH=0
[[ "${1:-}" == "--publish" ]] && PUBLISH=1
PROFILE="${NOTARY_PROFILE:-snazzy-notary}"

xcodegen --quiet
TEAM=$(xcodebuild -scheme SnazzyPro -configuration Release -showBuildSettings 2>/dev/null | awk '$1 == "DEVELOPMENT_TEAM" {print $3; exit}')
VERSION=$(xcodebuild -scheme SnazzyPro -configuration Release -showBuildSettings 2>/dev/null | awk '$1 == "MARKETING_VERSION" {print $3; exit}')
if [[ -z "$TEAM" ]]; then
  echo "Set DEVELOPMENT_TEAM = <your team ID> in Config/Local.xcconfig" >&2
  exit 1
fi
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "No 'Developer ID Application' certificate found. Create one in Xcode › Settings › Accounts › Manage Certificates." >&2
  exit 1
fi

# Tests first: never ship a red build.
swift test --package-path Packages/SnazzyKit

OUT=build/direct
ARCHIVE=$OUT/SnazzyPro.xcarchive
rm -rf "$OUT"
mkdir -p "$OUT"

echo "› Archiving (universal: arm64 + x86_64)"
xcodebuild archive -quiet \
  -scheme SnazzyPro -configuration Release -archivePath "$ARCHIVE" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM="$TEAM" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" ENABLE_HARDENED_RUNTIME=YES

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
PLIST

echo "› Exporting"
xcodebuild -exportArchive -quiet -archivePath "$ARCHIVE" -exportPath "$OUT/export" -exportOptionsPlist "$OUT/ExportOptions.plist"
APP="$OUT/export/SnazzyPro.app"
echo "  architectures: $(lipo -archs "$APP/Contents/MacOS/SnazzyPro")"

echo "› Building the DMG"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/Snazzy Pro.app"
ln -s /Applications "$STAGE/Applications"
DMG="build/SnazzyPro-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname "Snazzy Pro" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
codesign --sign "Developer ID Application" --timestamp "$DMG"

echo "› Notarizing (a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

echo "› Checking Gatekeeper accepts it"
spctl --assess --type open --context context:primary-signature -v "$DMG"
shasum -a 256 "$DMG" | tee "$DMG.sha256"

if [[ $PUBLISH == 1 ]]; then
  echo "› Publishing to the mac-beta release"
  cp "$DMG" build/SnazzyPro.dmg
  shasum -a 256 build/SnazzyPro.dmg > build/SnazzyPro.dmg.sha256
  gh release view mac-beta >/dev/null 2>&1 || gh release create mac-beta --prerelease \
    --title "Snazzy Pro for Mac (beta)" \
    --notes "Direct download for macOS 15 or later, Apple Silicon and Intel. Signed with Developer ID and notarized by Apple."
  gh release upload mac-beta build/SnazzyPro.dmg build/SnazzyPro.dmg.sha256 "$DMG" --clobber
  gh release edit mac-beta --notes "Snazzy Pro $VERSION for macOS 15 or later (Apple Silicon and Intel). Signed with Developer ID and notarized by Apple. SHA-256: $(cut -d' ' -f1 build/SnazzyPro.dmg.sha256)"
fi
echo "Done: $DMG"
