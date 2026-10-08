# Direct download (signed, notarized DMG)

Until the Mac App Store launch, Snazzy Pro is offered as a direct download:
one universal DMG (Apple Silicon and Intel, macOS 15 or later), signed with
Developer ID and notarized by Apple, so it opens without Gatekeeper warnings.

## One-time setup (account holder)

1. **Developer ID Application certificate.** Xcode › Settings › Accounts ›
   your team › Manage Certificates › **+** › **Developer ID Application**. Only
   the Apple Developer account holder can create it. Check it's there:
   `security find-identity -v -p codesigning | grep "Developer ID Application"`
2. **Notarization credentials.** Create an app-specific password at
   https://account.apple.com (Sign-In and Security › App-Specific Passwords), then:
   ```sh
   xcrun notarytool store-credentials snazzy-notary \
     --apple-id <your Apple ID> --team-id <team ID> --password <app-specific password>
   ```
   The password is saved in your keychain, not in the repo.

## Each release

```sh
Scripts/release-dmg.sh             # build/SnazzyPro-<version>.dmg, notarized and stapled
Scripts/release-dmg.sh --publish   # …and publish it as the website download
```

The website's download button points at
`https://github.com/bwalia/snazzy/releases/download/mac-beta/SnazzyPro.dmg`.

## Notes

- In-app purchases only work in the App Store version; the direct download is
  the free app (Pro unlocking for direct downloads would need its own licence
  keys, if wanted).
- Apple's on-device AI model needs Apple Silicon; on Intel Macs people use
  Ollama or a cloud AI provider.
- Bump `MARKETING_VERSION` in `project.yml` for each release.
