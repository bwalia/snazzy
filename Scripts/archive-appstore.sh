#!/bin/bash
# Archives Snazzy Pro for the Mac App Store and exports a signed .pkg.
#
#   Scripts/archive-appstore.sh            # archive + export to build/AppStore
#   Scripts/archive-appstore.sh --upload   # archive + upload to App Store Connect
#
# Needs: Xcode signed in to your Apple developer account (Xcode › Settings ›
# Accounts), DEVELOPMENT_TEAM in Config/Local.xcconfig, and the app record
# created in App Store Connect with the same bundle ID.
set -euo pipefail
cd "$(dirname "$0")/.."

DESTINATION=export
[[ "${1:-}" == "--upload" ]] && DESTINATION=upload

xcodegen --quiet
TEAM=$(xcodebuild -scheme SnazzyPro -configuration Release -showBuildSettings 2>/dev/null | awk '$1 == "DEVELOPMENT_TEAM" {print $3; exit}')
if [[ -z "$TEAM" ]]; then
  echo "Set DEVELOPMENT_TEAM = <your team ID> in Config/Local.xcconfig" >&2
  exit 1
fi

# Tests first: never ship a red build.
swift test --package-path Packages/SnazzyKit

ARCHIVE=build/SnazzyPro.xcarchive
rm -rf "$ARCHIVE" build/AppStore
xcodebuild archive \
  -scheme SnazzyPro -configuration Release -archivePath "$ARCHIVE" \
  CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM="$TEAM" \
  -allowProvisioningUpdates

cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$DESTINATION</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST

xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist build/ExportOptions.plist \
  -exportPath build/AppStore -allowProvisioningUpdates

if [[ "$DESTINATION" == upload ]]; then
  echo "Uploaded. It appears in App Store Connect › TestFlight after processing (10–30 min)."
else
  echo "Exported to build/AppStore. Upload with: Scripts/archive-appstore.sh --upload (or Transporter)."
fi
