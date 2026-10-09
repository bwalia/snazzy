# Free and Pro: licensing and pricing plan

*Status: decided, not yet enforced. Snazzy Pro is a free beta, so every feature
stays unlocked until launch.*

**Decisions (October 2026):**
- The bundle ID stays `com.snazzy.pro`, so the products are
  `com.snazzy.pro.pro.lifetime` and `com.snazzy.pro.pro.updates`.
- The $99 tier is a non-renewing purchase, bought again by hand.
- The Pro features are the split below. The list, with each feature's
  release date, is data in
  `Packages/SnazzyKit/Sources/Entitlements/Resources/pro-features.json`.
- Direct-download licences come from OpsAPI: licence files in its format v1
  (ES256 compact JWS, keys rotated through a JWKS), checked offline. The OpsAPI
  app's feature keys must be the ids in `pro-features.json`, and the app keeps
  the licence's `highWater` so turning the clock back doesn't extend it.

## Model: open core

| | Free (open source) | Pro (paid, closed) |
|---|---|---|
| Licence | Apache-2.0, in this public repo | Proprietary EULA (Apple's standard EULA on the App Store) |
| Where the code lives | `github.com/bwalia/snazzy` | A **private** repo/package, linked only into official builds |
| Who can build it | Anyone (without our brand, see `TRADEMARKS.md`) | Only us |

**Why Apache-2.0** for the core:
- **App Store compatible.** GPL-family licences conflict with App Store terms
  for third-party contributions (that's why VLC was pulled in 2011).
- **Explicit patent grant and patent-retaliation clause**, which MIT lacks.
  This matters for capture, AI and video code.
- **Contributions can ship in the paid app** without a CLA (inbound = outbound,
  plus a DCO sign-off).
- **Widely trusted** by companies and individual contributors.
- **The brand stays protected:** the licence excludes trademarks, so forks
  can't call themselves Snazzy Pro.

**Alternatives considered:**
- *MIT:* simpler, but no patent grant.
- *AGPL or GPL:* would stop closed forks, but conflicts with App Store
  distribution and scares off businesses.
- *BUSL or fair-source:* not open source, which contradicts "basic features are
  open source".

## Pricing (as requested)

- **Snazzy Pro: free** to download and use.
- **Pro, $49, one-off:** unlocks every Pro feature available on the day you buy,
  forever, plus fixes.
- **Pro + 1 year of new features, $99:** unlocks Pro, plus every new Pro
  feature released in the next 12 months, kept forever. Buy again later to get
  another year of new features.

### How that maps to the Mac App Store (StoreKit 2)

The App Store requires in-app purchase to unlock features in an App Store app
(guideline 3.1.1). License keys are only allowed in a direct-download build.

| Product | App Store type | Price | Unlocks |
|---|---|---|---|
| `<bundle-id>.pro.lifetime` | Non-Consumable | $49 | Pro features released up to the purchase date |
| `<bundle-id>.pro.updates` | **Non-Renewing Subscription** (1 year) | $99 | Pro, plus Pro features released up to purchase date + 1 year (stacks if bought again) |

Rule in the app: each Pro feature has a release date. It's unlocked if any
purchase "covers" that date: a lifetime purchase covers dates up to its purchase
date; an updates purchase covers one year from its purchase date, or from the
end of the year already bought if that's later.
Purchases are read with `Transaction.all` (`currentEntitlements` only has the
latest non-renewing transaction, which would lose stacked years);
**Restore Purchases** is in Settings. One purchase also covers the future
iPhone/iPad app (Universal Purchase).

**Still to decide:** should buyers of the $49 tier get an upgrade price to the
$99 tier? The App Store has no native upgrade pricing; it's usually done with a
separate discounted product or offer codes.

## The split

| Free (open source) | Pro |
|---|---|
| Chat with any model: Apple on-device, Ollama, your own Claude key | Camera backgrounds: image replacement and built-ins (blur stays free) |
| Builder: HTML decks and prototypes | Re-laying out the inset after recording, from raw tracks (phase 7) |
| Devices, previews, camera inset, crop | 4K export, vertical clips, captions burned in (phase 7) |
| Recording at 1080p with the camera inset, pause and resume | Teleprompter and present-and-record slides mode (phase 6) |
| Presets (up to 3) | Unlimited presets |
| MCP: connect data sources | MCP: let AI agents drive Snazzy Pro |
| Session record | Clap-calibrated lip sync (phase 5) |

Principle: everything needed to make a good recording is free; Pro saves time
and adds polish.

## Implementation plan

1. **Done:** the `Entitlements` module in SnazzyKit.
   - The catalogue and the coverage rules: lifetime, plus update years that
     stack.
   - `isUnlocked(_:)` and `limit(_:)`.
   - The licence verifier and the machine fingerprint.
   - Its policy is `freeBeta` (everything unlocked) until launch. At launch
     the app checks it before each Pro feature and switches it to `enforced`.
2. A private `SnazzyProFeatures` Swift package containing the Pro features and
   StoreKit purchase UI. `project.yml` includes it only when it's present
   (official builds).
3. **Done:** StoreKit 2 (`App/Sources/PurchaseController.swift`).
   - It reads verified, unrefunded purchases from `Transaction.all` into the
     Entitlements rules, so stacked years count, and listens for new ones.
   - It handles purchase results (including Ask to Buy) and Restore
     Purchases (`AppStore.sync()`).
   - While the policy is `freeBeta` it does nothing at all.
   - `App/Resources/SnazzyPro.storekit` is a local App Store with both products
     ($49, $99), used by the Xcode scheme and by `--store-test`. It's left out
     of Release builds.
   - The real products are created in App Store Connect with the same IDs (see
     `docs/launch/APP_STORE_CONNECT_SETUP.md`).
4. **Done:** the Pro screen (`Views/ProView.swift`), shown as a Settings tab
   once Pro is enforced.
   - It lists what Pro adds, with what you have unlocked.
   - It shows both tiers with App Store prices, and "Purchased" on a lifetime
     tier you already own.
   - It has Restore Purchases, Terms of Use (Apple's standard EULA) and the
     Privacy Policy, as App Review requires.
   - Try it in a debug build with `-SnazzyPro.enforcePro YES`, run from Xcode
     so the local App Store is used.
5. To do at launch:
   - Switch `PurchaseController.policy` to `.enforced`.
   - Check `isUnlocked` before each Pro feature, and offer the Pro screen when
     it's locked.
   - Sell direct-download licences through OpsAPI (StoreKit only works in the
     Mac App Store build).
