# Free and Pro: licensing and pricing plan

*Status: proposal. The free/Pro split and the exact App Store products need sign-off.*

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
date; an updates purchase covers dates up to its purchase date plus 365 days.
Purchases are read with `Transaction.currentEntitlements` / `Transaction.all`;
**Restore Purchases** is in Settings. One purchase also covers the future
iPhone/iPad app (Universal Purchase).

**Things to confirm:**
1. **Is "1 year of updates" a non-renewing purchase (bought again by hand), or
   an auto-renewing $99/year subscription?** Auto-renewing earns more and is
   less friction, but subscriptions get more App Review scrutiny and must
   provide ongoing value.
2. **Should buyers of the $49 tier get an upgrade price to the $99 tier?**
   The App Store has no native upgrade pricing; it's usually done with a
   separate discounted product or offer codes.
3. **Which features are Pro** (below).

## Suggested split (draft)

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

1. A small `Entitlements` module in the open core: `ProFeature` with release
   dates, plus `isUnlocked(_:)`. The open-source build always says "locked" and
   simply doesn't contain the Pro code paths.
2. A private `SnazzyProFeatures` Swift package containing the Pro features and
   StoreKit purchase UI. `project.yml` includes it only when it's present
   (official builds).
3. A StoreKit configuration file for local testing and TestFlight, with
   products created in App Store Connect (see `docs/launch/APP_STORE_CONNECT_SETUP.md`).
4. A paywall sheet that shows both tiers clearly, with Restore Purchases, Terms
   of Use (Apple's standard EULA) and Privacy links (required by App Review).
