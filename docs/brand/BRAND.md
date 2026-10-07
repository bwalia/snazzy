# Snazzy Pro brand

**Snazzy Pro is your presentation studio, run by conversation.** You talk; it
plans the deck, builds the slides or prototype, sets up the cameras, records
and exports the video.

## Name

- Write **Snazzy Pro**: two words, both capitalised. Not "SnazzyPro",
  "Snazzy pro" or "SNAZZY PRO". (The app bundle and code use `SnazzyPro`;
  people never see that.)
- Short form in running text: **Snazzy**.

## Taglines

- Primary: **Just say it.**
- Alternatives: *Talk. Build. Record.* · *From idea to on-camera in one conversation.*

## Logo

| File | Use |
|---|---|
| `logo-icon.svg` | App icon (macOS grid: 824 px body on a 1024 canvas). Rendered into `App/Resources/Assets.xcassets/AppIcon.appiconset`. |
| `logo-icon-small.svg` | App icon at 16–32 px (one sparkle, thicker inset border, bigger dot). |
| `logo-glyph.svg` | The mark without the icon background: favicons, in-app, social avatars. |
| `logo-mono.svg` | One-colour mark (`currentColor`), for embossing, watermarks and single-colour print. |
| `lockup.svg` / `lockup-on-dark.svg` | Glyph + wordmark, the default logo. |
| `wordmark.svg` / `wordmark-on-dark.svg` | Wordmark alone, where the glyph is already shown nearby. |
| `png/` | PNG renders (`@2x`). |

**The mark** is the product in one picture: a vivid stage (your slide or
screen) with an AI sparkle, and a camera inset in the corner with a live
record dot.

- **Clear space:** keep free space around the logo equal to the height of the
  camera inset in the glyph.
- **Minimum size:** the glyph is 16 px tall on screen, and the lockup is 120 px wide.
- **Don't:** recolour the gradient, rotate, stretch, add effects or outlines,
  move the inset to another corner, or put the full-colour logo on busy photos.
  Use the mono mark there instead.
- The wordmark is **Manrope ExtraBold** converted to outlines (SIL Open Font
  License, `fonts/OFL.txt`), so it renders the same everywhere.

## Colour

| Token | Hex | Role |
|---|---|---|
| Ink | `#0B1020` | Dark backgrounds, wordmark on light |
| Night | `#141A33` | Dark surfaces, cards |
| Violet | `#6C5CFF` | Primary / accent (app accent colour; `#8B7BFF` in dark mode) |
| Magenta | `#D946EF` | Gradient middle, highlights |
| Coral | `#FF6A55` | Gradient end, warm highlights |
| Record | `#FF4D5E` | Recording only: the record dot, record button, "recording" state |
| Live | `#34D399` | Live feeds, local (on-device) models, success |
| Cloud | `#FFB020` | Cloud models / content leaving the Mac, warnings |
| Mist | `#E8EAF6` | Light surfaces |
| Slate | `#8A93B5` | Secondary text on dark |

**Spotlight gradient:** 135°, Violet `#6C5CFF` → Magenta `#D946EF` (52%) → Coral `#FF6A55`.
Use it for the mark, hero moments and the "Pro" pill. Don't use it behind body text.

Red means **recording** and nothing else, so the record dot stays meaningful.

## Typography

- **Brand and marketing:** Manrope (ExtraBold 800 for headlines, SemiBold 600
  for subheads, Regular 400 for body).
- **In the app:** the macOS system font (SF Pro / SF Mono). It is native,
  accessible and matches the platform. Apple's licence doesn't allow SF fonts
  in the logo or marketing, which is why the brand uses Manrope.
- **Code in marketing:** JetBrains Mono (OFL).

## Shape and motion

- Generous rounded corners (about 18% of a shape's height), echoing the stage and inset.
- The **picture-in-picture** motif (a small rounded box in a corner of a
  larger one) is the brand's signature. Use it for illustrations and empty states.
- Motion is quick and calm: 150–250 ms, ease-out. Only the record dot pulses,
  and only while recording.

## Voice

Plain, confident, warm. Short sentences. Say what happens, not how clever it is.

| Do | Don't |
|---|---|
| "Recording saved. 4:12, no dropped frames." | "Your amazing masterpiece has been successfully saved!" |
| "Your iPad isn't sending video. Is it unlocked?" | "Error -11819: device stall detected." |
| "Built a 6-slide deck. Want a darker theme?" | "As an AI, I have generated slides for you." |
