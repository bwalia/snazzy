//! Decks: the outline in `deck.json` (Builder/DeckOutline.swift), the slide
//! layouts and the HTML they render to (Builder/SampleDecks.swift `deckHTML`,
//! `render`), and the starter files (Builder/Templates.swift). Byte for byte the
//! same as the Mac. Spec: docs/specs/decks.md.

use serde::{Deserialize, Serialize};

use crate::json;
use crate::project::ProjectKind;

pub const OUTLINE_FILE: &str = "deck.json";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Layout {
    /// heading = title, items[0] = subtitle
    Title,
    Bullets,
    /// items = [value, caption] pairs
    Stats,
    /// items split in half: left column, right column; first item of each is its label
    Columns,
    /// heading = quote, items[0] = who said it
    Quote,
    /// numbered steps
    Steps,
    /// heading = call to action, items[0] = detail
    Closing,
}

impl Layout {
    pub const ALL: [Layout; 7] = [
        Layout::Title,
        Layout::Bullets,
        Layout::Stats,
        Layout::Columns,
        Layout::Quote,
        Layout::Steps,
        Layout::Closing,
    ];

    pub fn raw(self) -> &'static str {
        match self {
            Layout::Title => "title",
            Layout::Bullets => "bullets",
            Layout::Stats => "stats",
            Layout::Columns => "columns",
            Layout::Quote => "quote",
            Layout::Steps => "steps",
            Layout::Closing => "closing",
        }
    }

    /// Names for the editor.
    pub fn display_name(self) -> &'static str {
        match self {
            Layout::Title => "Title",
            Layout::Bullets => "Bullet points",
            Layout::Stats => "Big numbers",
            Layout::Columns => "Two columns",
            Layout::Quote => "Quote",
            Layout::Steps => "Numbered steps",
            Layout::Closing => "Closing",
        }
    }

    /// How the editor's lines map to the layout.
    pub fn items_hint(self) -> &'static str {
        match self {
            Layout::Title | Layout::Closing => "Subtitle (one line)",
            Layout::Bullets => "One bullet per line",
            Layout::Steps => "One step per line",
            Layout::Stats => "Pairs of lines: number, then what it means",
            Layout::Columns => {
                "Left label, its points, then right label and its points (split in half)"
            }
            Layout::Quote => "Who said it (one line)",
        }
    }
}

/// One slide of an outline or a sample deck. All fields are required in deck.json.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Slide {
    pub layout: Layout,
    pub heading: String,
    pub items: Vec<String>,
    pub notes: String,
}

impl Slide {
    pub fn new(layout: Layout, heading: &str, items: &[&str], notes: &str) -> Self {
        Self {
            layout,
            heading: heading.into(),
            items: items.iter().map(|s| s.to_string()).collect(),
            notes: notes.into(),
        }
    }
}

/// `deck.json`: a deck the slide editor can make and change without AI.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct DeckOutline {
    pub title: String,
    pub accent: String,
    pub slides: Vec<Slide>,
}

impl DeckOutline {
    pub const DEFAULT_ACCENT: &'static str = "#6C5CFF";
    /// Accent colours offered in the editor.
    pub const ACCENTS: [&'static str; 8] = [
        "#6C5CFF", "#D946EF", "#FF6A55", "#FFB020", "#34D399", "#38BDF8", "#0F766E", "#3B82F6",
    ];

    /// A new deck to start from.
    pub fn starter(title: &str) -> Self {
        Self {
            title: title.into(),
            accent: Self::DEFAULT_ACCENT.into(),
            slides: vec![
                Slide::new(
                    Layout::Title,
                    title,
                    &["Subtitle"],
                    "Introduce yourself and the topic.",
                ),
                Slide::new(
                    Layout::Bullets,
                    "What we'll cover",
                    &["First point", "Second point", "Third point"],
                    "",
                ),
                Slide::new(Layout::Closing, "Thank you", &["Questions?"], ""),
            ],
        }
    }

    /// deck.json as the Mac writes it (pretty, sorted keys, `\/`, trailing newline).
    pub fn to_json(&self) -> String {
        json::to_string(self, json::Style::PRETTY).unwrap_or_default() + "\n"
    }

    pub fn from_json(data: &[u8]) -> Option<Self> {
        serde_json::from_slice(data).ok()
    }

    /// index.html for the outline.
    pub fn html(&self) -> String {
        deck_html(&self.title, &self.accent, &self.slides, None)
    }
}

/// `SampleDeck.esc`: `& < > "` as entities.
pub fn esc(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

/// A complete deck page in the house style (deck.css + deck.js).
pub fn deck_html(title: &str, accent: &str, slides: &[Slide], comment: Option<&str>) -> String {
    let sections: Vec<String> = slides.iter().map(render).collect();
    let note = comment
        .map(|c| format!("  <!-- {} -->\n", esc(c)))
        .unwrap_or_default();
    format!(
        "<!doctype html>\n<html lang=\"en\">\n<head>\n  <meta charset=\"utf-8\">\n  <title>{}</title>\n  <link rel=\"stylesheet\" href=\"deck.css\">\n</head>\n<body style=\"--accent: {}\">\n{}  <div class=\"deck\">\n{}\n  </div>\n  <div class=\"counter\"></div>\n  <script src=\"deck.js\"></script>\n</body>\n</html>\n",
        esc(title),
        esc(accent),
        note,
        sections.join("\n")
    )
}

fn list(items: &[String]) -> String {
    items
        .iter()
        .map(|i| format!("<li>{}</li>", esc(i)))
        .collect()
}

/// One `<section class="slide">`.
pub fn render(s: &Slide) -> String {
    let h = esc(&s.heading);
    let notes = if s.notes.is_empty() {
        String::new()
    } else {
        format!("\n      <aside class=\"notes\">{}</aside>", esc(&s.notes))
    };
    let first = |f: &dyn Fn(&str) -> String| s.items.first().map(|i| f(i)).unwrap_or_default();
    let body = match s.layout {
        Layout::Title | Layout::Closing => {
            format!("<h1>{h}</h1>") + &first(&|i| format!("<p class=\"subtitle\">{}</p>", esc(i)))
        }
        Layout::Bullets => format!("<h2>{h}</h2><ul>{}</ul>", list(&s.items)),
        Layout::Steps => format!("<h2>{h}</h2><ol class=\"steps\">{}</ol>", list(&s.items)),
        Layout::Stats => {
            let pairs: String = s
                .items
                .chunks_exact(2)
                .map(|p| {
                    format!(
                        "<div class=\"stat\"><b>{}</b><span>{}</span></div>",
                        esc(&p[0]),
                        esc(&p[1])
                    )
                })
                .collect();
            format!("<h2>{h}</h2><div class=\"stats\">{pairs}</div>")
        }
        Layout::Columns => {
            let half = s.items.len().div_ceil(2);
            let column = |items: &[String]| match items.split_first() {
                None => "<div></div>".to_string(),
                Some((label, rest)) => {
                    format!("<div><h3>{}</h3><ul>{}</ul></div>", esc(label), list(rest))
                }
            };
            format!(
                "<h2>{h}</h2><div class=\"cols\">{}{}</div>",
                column(&s.items[..half]),
                column(&s.items[half..])
            )
        }
        Layout::Quote => {
            format!("<blockquote>{h}</blockquote>")
                + &first(&|i| format!("<p class=\"by\">— {}</p>", esc(i)))
        }
    };
    let class = match s.layout {
        Layout::Title | Layout::Closing => "slide title".to_string(),
        other => format!("slide layout-{}", other.raw()),
    };
    format!("    <section class=\"{class}\">\n      {body}{notes}\n    </section>")
}

/// The starter files for a new project (`Templates.files`), in the Mac's order.
/// The title is escaped for `<` and `>` only, as on the Mac.
pub fn template_files(kind: ProjectKind, title: &str) -> Vec<(&'static str, String)> {
    let safe = title.replace('<', "&lt;").replace('>', "&gt;");
    let t = |s: &str| s.replace("{TITLE}", &safe);
    match kind {
        ProjectKind::Prototype => vec![
            ("index.html", t(PROTOTYPE_INDEX)),
            ("style.css", PROTOTYPE_CSS.to_string()),
            ("app.js", PROTOTYPE_JS.to_string()),
        ],
        ProjectKind::Presentation => vec![
            ("index.html", t(PRESENTATION_INDEX)),
            ("deck.css", DECK_CSS.to_string()),
            ("deck.js", DECK_JS.to_string()),
        ],
    }
}

// The house style. Kept identical to Builder/Templates.swift (tests compare with
// the fixtures the Swift code writes).

const PRESENTATION_INDEX: &str = r##"<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>{TITLE}</title>
  <link rel="stylesheet" href="deck.css">
</head>
<body>
  <!-- One <section class="slide"> per slide. Speaker notes go in <aside class="notes">. -->
  <div class="deck">
    <section class="slide title">
      <h1>{TITLE}</h1>
      <p class="subtitle">Subtitle</p>
      <aside class="notes">Speaker notes for the title slide.</aside>
    </section>
    <section class="slide">
      <h2>Agenda</h2>
      <ul><li>First point</li><li>Second point</li><li>Third point</li></ul>
    </section>
  </div>
  <div class="counter"></div>
  <script src="deck.js"></script>
</body>
</html>
"##;

const DECK_CSS: &str = r##":root { --bg: #0f1420; --fg: #f2f4f8; --muted: #9aa3b5; --accent: #5b8cff; }
html, body { margin: 0; height: 100%; background: #000; overflow: hidden;
  font-family: -apple-system, system-ui, sans-serif; }
.deck { position: absolute; inset: 0; display: grid; place-items: center; }
.slide { display: none; width: 1600px; height: 900px; padding: 90px 110px; box-sizing: border-box;
  background: var(--bg); color: var(--fg); transform-origin: center; position: absolute; }
.slide.active { display: flex; flex-direction: column; justify-content: center; }
.slide h1 { font-size: 96px; margin: 0 0 24px; }
.slide h2 { font-size: 64px; margin: 0 0 40px; color: var(--accent); }
.slide p, .slide li { font-size: 40px; line-height: 1.4; }
.slide .subtitle { color: var(--muted); }
.slide.title h1 { background: linear-gradient(90deg, var(--fg), var(--accent));
  -webkit-background-clip: text; background-clip: text; color: transparent; }
.slide.title::after { content: ""; width: 160px; height: 8px; border-radius: 4px;
  background: var(--accent); margin-top: 36px; }
.slide h3 { font-size: 34px; margin: 0 0 12px; color: var(--muted); text-transform: uppercase; letter-spacing: 2px; }
.stats { display: flex; gap: 48px; }
.stat { flex: 1; border-top: 6px solid var(--accent); padding-top: 24px; }
.stat b { display: block; font-size: 110px; line-height: 1; }
.stat span { display: block; font-size: 32px; color: var(--muted); margin-top: 16px; }
.cols { display: grid; grid-template-columns: 1fr 1fr; gap: 64px; }
.cols ul { padding-left: 1.1em; margin: 0; }
.steps { counter-reset: step; list-style: none; padding: 0; margin: 0; }
.steps li { counter-increment: step; display: flex; align-items: center; gap: 28px; margin: 0 0 22px; }
.steps li::before { content: counter(step); flex: none; width: 64px; height: 64px; border-radius: 50%;
  background: var(--accent); color: var(--bg); display: grid; place-items: center; font-weight: 700; }
.slide blockquote { font-size: 76px; line-height: 1.2; margin: 0; padding-left: 48px;
  border-left: 10px solid var(--accent); font-weight: 600; }
.slide .by { color: var(--muted); padding-left: 58px; }
.slide .notes { display: none; }
.counter { position: fixed; right: 16px; bottom: 12px; color: #888; font-size: 14px; }
"##;

const DECK_JS: &str = r##"// 16:9 slides scaled to the window. Arrow keys / space / click to navigate.
const slides = [...document.querySelectorAll('.slide')];
// The counter is optional in index.html; add it if it's missing.
const counter = document.querySelector('.counter') ||
  document.body.appendChild(Object.assign(document.createElement('div'), { className: 'counter' }));
let current = Math.min(Number(location.hash.slice(1)) || 0, slides.length - 1);
function fit() {
  const s = Math.min(innerWidth / 1600, innerHeight / 900);
  slides.forEach(el => el.style.transform = `scale(${s})`);
}
function show(i) {
  current = Math.max(0, Math.min(i, slides.length - 1));
  slides.forEach((el, n) => el.classList.toggle('active', n === current));
  counter.textContent = `${current + 1} / ${slides.length}`;
  history.replaceState(null, '', '#' + current);
}
addEventListener('resize', fit);
addEventListener('keydown', e => {
  if (['ArrowRight', 'PageDown', ' '].includes(e.key)) show(current + 1);
  if (['ArrowLeft', 'PageUp'].includes(e.key)) show(current - 1);
});
addEventListener('click', () => show(current + 1));
window.snazzyDeck = { show, count: () => slides.length, current: () => current };
fit(); show(current);
"##;

const PROTOTYPE_INDEX: &str = r##"<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{TITLE}</title>
  <link rel="stylesheet" href="style.css">
</head>
<body>
  <main id="app">
    <h1>{TITLE}</h1>
    <p>Prototype starting point.</p>
  </main>
  <script src="app.js"></script>
</body>
</html>
"##;

const PROTOTYPE_CSS: &str = r##":root { color-scheme: light dark; --accent: #4f7cff; }
* { box-sizing: border-box; }
body { margin: 0; font: 16px/1.5 -apple-system, system-ui, sans-serif; }
main { max-width: 960px; margin: 0 auto; padding: 32px 24px; }
"##;

const PROTOTYPE_JS: &str = r##"// App logic goes here.
document.addEventListener('DOMContentLoaded', () => {});
"##;
