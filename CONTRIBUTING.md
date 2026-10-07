# Contributing to Snazzy Pro

Thanks for helping. Snazzy Pro is **open core**: the app's core is open source
under the Apache License 2.0 (this repository), and the paid "Pro" features are
developed separately and closed.

## Licence of contributions

Under the Apache License 2.0 (section 5), contributions you submit are licensed
under the same licence ("inbound = outbound"). Because Apache-2.0 is permissive,
contributions may also ship in the official app, including its paid builds on
the Mac App Store.

Every commit must be signed off to certify the
[Developer Certificate of Origin](https://developercertificate.org): that you
wrote it or have the right to submit it under this licence.

```sh
git commit -s -m "Explain what changed"
```

## Before opening a pull request

```sh
swift test --package-path Packages/SnazzyKit     # all tests must pass
xcodegen && xcodebuild -scheme SnazzyPro build   # no warnings in new code
```

- Match the surrounding code style. Add tests for new logic.
- Never commit API keys, tokens, personal paths, or signing identities.
  `Config/Local.xcconfig` is git-ignored for that reason.
- Don't add the Snazzy Pro brand assets to forks you publish (see `TRADEMARKS.md`).
