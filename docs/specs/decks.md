# Decks

A deck is a project folder with `index.html`, `deck.css`, `deck.js` and, when
made in the slide editor (or from a sample), `deck.json`.

Source of truth: `Packages/SnazzyKit/Sources/Builder/DeckOutline.swift`,
`SampleDecks.swift` (`deckHTML`, `render`, `esc`, `SampleDeck.all`),
`Templates.swift`.
Fixtures: `deck.json`, `deck-outline.html`, `deck-starter.json`, `samples.json`,
`deck-<id>.html` (three samples), `template-presentation-index.html`, `deck.css`,
`deck.js`, `template-prototype-*`, `templates.json`.
Rust: `snazzy_core::{deck, samples}`.

## The deck contract

Everything that shows or records slides (Present window, slide capture, remotes,
chapters, `check_preview`) relies on:

- `window.snazzyDeck = { show, count, current }` (from `deck.js`): `show(i)`
  0-based, `count()`, `current()`;
- one `<section class="slide">` per slide;
- speaker notes in `<aside class="notes">` inside the section.

Decks written by the assistant may differ in everything else.

## `deck.json`

`{"accent":"#6C5CFF","slides":[{"heading":…,"items":[…],"layout":…,"notes":…}],"title":…}`,
every field required, pretty-printed with sorted keys and `\/`, plus a final
newline (README). Saving also writes `index.html` from it (unless asked not to)
and adds `deck.css`/`deck.js` when missing.

Layouts and their items:

| `layout` | Section class | Body |
|---|---|---|
| `title` | `slide title` | `<h1>heading</h1>` + `<p class="subtitle">items[0]</p>` |
| `closing` | `slide title` | same as `title` |
| `bullets` | `slide layout-bullets` | `<h2>` + `<ul><li>…</li></ul>` |
| `steps` | `slide layout-steps` | `<h2>` + `<ol class="steps"><li>…</li></ol>` |
| `stats` | `slide layout-stats` | `<h2>` + `<div class="stats">` with `<div class="stat"><b>value</b><span>caption</span></div>` per pair (an odd last item is dropped) |
| `columns` | `slide layout-columns` | `<h2>` + `<div class="cols">`, items split at ⌈n/2⌉; each half `<div><h3>first</h3><ul>rest</ul></div>`, or `<div></div>` when empty |
| `quote` | `slide layout-quote` | `<blockquote>heading</blockquote>` + `<p class="by">— items[0]</p>` |

Every text is escaped `&`, `<`, `>`, `"`. Notes, when not empty, follow the body
on their own line as `<aside class="notes">`. The page around the sections
(title, `--accent` on `<body>`, optional `<!-- comment -->`, counter, script) is
in `deck-outline.html`; the HTML must be **byte-identical** to the Mac's.

## Starter files

`Templates.files(kind, title)`, in this order: presentation `index.html`,
`deck.css`, `deck.js`; prototype `index.html`, `style.css`, `app.js`. The title
is escaped for `<` and `>` only. Byte-identical (fixtures use the title
`Q3 <Results> & "more"`).

## Samples

`samples.json` is `SampleDeck.all` (13 decks, 12 sectors): `id`, `sector` (its
display name, also the category when opened), `title`, `useCase`, `audience`,
`minutes`, `setup`, `prompt`, `accent`, `slides`, `projectName` (`sample-<id>`).
The Rust app **embeds this file** rather than re-typing the decks. A sample's
`index.html` is `deckHTML` with the comment
`Sample deck (<sector>). All names and figures are made up.`. Opening a sample
creates project `sample-<id>` (or opens the existing copy), writes its files and
`deck.json` (keeping its `index.html`), then sets category = sector and tags = `["Sample"]`.
