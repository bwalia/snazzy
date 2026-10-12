//! Search across every slide's title, text and speaker notes, including the
//! samples not opened yet (Builder/DeckSearch.swift). Same results, scores and
//! snippets as the Mac for the same decks and query. Spec: docs/specs/search.md.

use std::sync::OnceLock;

use regex::Regex;

use crate::deck::Slide as OutlineSlide;
use crate::fold::fold;
use crate::project::{ProjectKind, trim};
use crate::samples::SampleDeck;
use crate::workspace::Workspace;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Slide {
    pub heading: String,
    pub text: String,
    pub notes: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Source {
    /// A project (opened samples are projects too).
    Project(String),
    /// A sample deck that hasn't been opened yet.
    Sample(String),
}

#[derive(Debug, Clone, PartialEq)]
pub struct Deck {
    pub source: Source,
    pub title: String,
    pub category: Option<String>,
    pub tags: Vec<String>,
    pub slides: Vec<Slide>,
    /// Unix seconds; samples have none.
    pub created: Option<i64>,
}

impl Deck {
    /// The category shown in the library when none was set.
    pub const UNCATEGORISED: &'static str = "Uncategorised";

    pub fn category_name(&self) -> &str {
        self.category.as_deref().unwrap_or(Self::UNCATEGORISED)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Field {
    Heading,
    Text,
    Notes,
}

impl Field {
    pub fn raw(self) -> &'static str {
        match self {
            Field::Heading => "heading",
            Field::Text => "text",
            Field::Notes => "notes",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hit {
    pub deck: Source,
    pub deck_title: String,
    /// 0-based, as `show_slide` and deck.js use it.
    pub slide: usize,
    pub heading: String,
    /// Where the best match is, and the text around it.
    pub field: Field,
    pub snippet: String,
    pub score: i64,
}

// MARK: Loading

/// Every presentation in the workspace, plus the samples that haven't been opened.
pub fn decks(workspace: &Workspace, samples: &[SampleDeck]) -> Vec<Deck> {
    let projects = workspace.list_projects();
    let mut out: Vec<Deck> = projects
        .iter()
        .filter(|p| p.kind == ProjectKind::Presentation)
        .filter_map(|p| deck(&p.name, workspace))
        .collect();
    for s in samples {
        if !projects.iter().any(|p| p.name == s.project_name) {
            out.push(sample_deck(s));
        }
    }
    out
}

/// A sample that hasn't been opened, as a search deck.
pub fn sample_deck(s: &SampleDeck) -> Deck {
    Deck {
        source: Source::Sample(s.id.clone()),
        title: s.title.clone(),
        category: Some(s.sector.clone()),
        tags: vec!["Sample".into()],
        slides: s.slides.iter().map(slide_from).collect(),
        created: None,
    }
}

/// A project's slides: from index.html when it has any, else from deck.json.
pub fn deck(project: &str, workspace: &Workspace) -> Option<Deck> {
    let mut deck = slides_only(project, workspace)?;
    let meta = workspace.project(project);
    deck.category = meta.as_ref().and_then(|m| m.category.clone()).or_else(|| {
        // Samples opened before decks had categories: their sector.
        crate::samples::all()
            .iter()
            .find(|s| s.project_name == project)
            .map(|s| s.sector.clone())
    });
    deck.tags = meta
        .as_ref()
        .and_then(|m| m.tags.clone())
        .unwrap_or_default();
    deck.created = meta.map(|m| m.created.unix());
    Some(deck)
}

fn slides_only(project: &str, workspace: &Workspace) -> Option<Deck> {
    let make = |title: String, slides: Vec<Slide>| Deck {
        source: Source::Project(project.into()),
        title,
        category: None,
        tags: vec![],
        slides,
        created: None,
    };
    let html = workspace.read(project, "index.html").ok();
    if let Some(outline) = workspace.load_outline(project) {
        if let Some(html) = &html {
            let slides = slides_from_html(html);
            if !slides.is_empty() {
                return Some(make(title_from_html(html).unwrap_or(outline.title), slides));
            }
        }
        return Some(make(
            outline.title.clone(),
            outline.slides.iter().map(slide_from).collect(),
        ));
    }
    let html = html?;
    let slides = slides_from_html(&html);
    if slides.is_empty() {
        return None;
    }
    Some(make(
        title_from_html(&html).unwrap_or_else(|| project.into()),
        slides,
    ))
}

pub fn slide_from(s: &OutlineSlide) -> Slide {
    Slide {
        heading: s.heading.clone(),
        text: s.items.join(" · "),
        notes: s.notes.clone(),
    }
}

fn re(cell: &'static OnceLock<Regex>, pattern: &str) -> &'static Regex {
    cell.get_or_init(|| Regex::new(pattern).expect("valid pattern"))
}

macro_rules! regex {
    ($pattern:expr) => {{
        static CELL: OnceLock<Regex> = OnceLock::new();
        re(&CELL, $pattern)
    }};
}

/// Removes `<script>…</script>` and `<style>…</style>` (the Mac uses one pattern
/// with a back-reference, `<(script|style)\b.*?</\1>`; Rust's regex has none).
fn strip_scripts(html: &str) -> String {
    let open = regex!(r"(?i)<(script|style)\b");
    let close_script = regex!(r"(?i)</script>");
    let close_style = regex!(r"(?i)</style>");
    let mut out = String::with_capacity(html.len());
    let mut copied = 0;
    let mut from = 0;
    while let Some(m) = open.captures_at(html, from) {
        let whole = m.get(0).expect("match");
        let close = if m[1].eq_ignore_ascii_case("script") {
            close_script
        } else {
            close_style
        };
        match close.find_at(html, whole.end()) {
            Some(end) => {
                out.push_str(&html[copied..whole.start()]);
                out.push(' ');
                copied = end.end();
                from = end.end();
            }
            None => {
                // No closing tag: try the next possible start.
                from = whole.start()
                    + html[whole.start()..]
                        .chars()
                        .next()
                        .map_or(1, char::len_utf8);
            }
        }
    }
    out.push_str(&html[copied..]);
    out
}

fn captures(re: &Regex, s: &str) -> Vec<String> {
    re.captures_iter(s)
        .filter_map(|c| c.get(1).map(|m| m.as_str().to_string()))
        .collect()
}

/// The `<section class="slide">` elements of a deck page, with their notes kept apart.
pub fn slides_from_html(html: &str) -> Vec<Slide> {
    let page = strip_scripts(html);
    let section = regex!(
        r#"(?is)<section\b[^>]*class\s*=\s*["'][^"']*\bslide\b[^"']*["'][^>]*>(.*?)</section>"#
    );
    let notes_re =
        regex!(r#"(?is)<aside\b[^>]*class\s*=\s*["'][^"']*\bnotes\b[^"']*["'][^>]*>(.*?)</aside>"#);
    let notes_strip =
        regex!(r#"(?is)<aside\b[^>]*class\s*=\s*["'][^"']*\bnotes\b[^"']*["'][^>]*>.*?</aside>"#);
    let heading_re = regex!(r"(?is)<(?:h1|h2|blockquote)\b[^>]*>(.*?)</(?:h1|h2|blockquote)>");
    captures(section, &page)
        .into_iter()
        .map(|body| {
            let notes: Vec<String> = captures(notes_re, &body).iter().map(|n| plain(n)).collect();
            let content = notes_strip.replace_all(&body, " ");
            let heading = captures(heading_re, &content)
                .first()
                .map(|h| plain(h))
                .unwrap_or_default();
            let mut text = plain(&content);
            if !heading.is_empty() && text.starts_with(&heading) {
                text = trim_spaces(&text[heading.len()..]).to_string();
            }
            Slide {
                heading,
                text,
                notes: notes.join(" "),
            }
        })
        .collect()
}

/// The page's `<title>`, if it has one with text.
pub fn title_from_html(html: &str) -> Option<String> {
    let title = regex!(r"(?is)<title\b[^>]*>(.*?)</title>");
    captures(title, html)
        .first()
        .map(|t| plain(t))
        .filter(|t| !t.is_empty())
}

/// Visible text of an HTML fragment: tags removed, entities decoded, spaces
/// collapsed; list items and column headings read as "a · b · c".
pub fn plain(html: &str) -> String {
    let s = regex!(r"(?i)</(li|h3|h4)>").replace_all(html, " · ");
    let s = regex!(r"(?i)<br\s*/?>|</(p|div|h\d|td|th|b|span)>").replace_all(&s, " ");
    let mut s = regex!(r"<[^>]+>").replace_all(&s, "").into_owned();
    for (entity, c) in [
        ("&nbsp;", " "),
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", "\""),
        ("&#39;", "'"),
        ("&apos;", "'"),
        ("&mdash;", "—"),
        ("&ndash;", "–"),
        ("&hellip;", "…"),
        ("&rarr;", "→"),
        ("&middot;", "·"),
        ("&amp;", "&"),
    ] {
        s = s.replace(entity, c);
    }
    let numeric = regex!(r"&#(x?)([0-9a-fA-F]+);");
    let s = numeric.replace_all(&s, |c: &regex::Captures| {
        let radix = if &c[1] == "x" { 16 } else { 10 };
        u32::from_str_radix(&c[2], radix)
            .ok()
            .and_then(char::from_u32)
            .map_or_else(|| c[0].to_string(), String::from)
    });
    let words: Vec<&str> = s
        .split(char::is_whitespace)
        .filter(|w| !w.is_empty())
        .collect();
    // No separators at the ends or twice in a row.
    let mut kept: Vec<&str> = words
        .iter()
        .enumerate()
        .filter(|&(i, w)| *w != "·" || (i > 0 && words[i - 1] != "·"))
        .map(|(_, w)| *w)
        .collect();
    while kept.first() == Some(&"·") {
        kept.remove(0);
    }
    while kept.last() == Some(&"·") {
        kept.pop();
    }
    kept.join(" ")
}

// MARK: Searching

fn starts_word(w: &str, s: &str) -> bool {
    let mut from = 0;
    while let Some(pos) = s[from..].find(w) {
        let at = from + pos;
        if s[..at]
            .chars()
            .next_back()
            .is_none_or(|c| !c.is_alphabetic())
        {
            return true;
        }
        from = at + s[at..].chars().next().map_or(1, char::len_utf8);
    }
    false
}

/// Slides containing every word of the query (ignoring case, accents and width), best first.
pub fn search(query: &str, decks: &[Deck], limit: usize) -> Vec<Hit> {
    let folded_query = fold(query);
    let words: Vec<&str> = folded_query
        .split(char::is_whitespace)
        .filter(|w| !w.is_empty())
        .collect();
    if words.is_empty() {
        return vec![];
    }
    let phrase = words.join(" ");
    let mut hits: Vec<Hit> = Vec::new();
    for deck in decks {
        let tags: Vec<String> = deck.tags.iter().map(|t| fold(t)).collect();
        let category = fold(deck.category.as_deref().unwrap_or(""));
        let title = fold(&deck.title);
        for (i, s) in deck.slides.iter().enumerate() {
            let (h, t, n) = (fold(&s.heading), fold(&s.text), fold(&s.notes));
            let mut score = 0i64;
            let mut all = true;
            for w in &words {
                if h.contains(w) {
                    score += if starts_word(w, &h) { 12 } else { 8 };
                } else if t.contains(w) {
                    score += if starts_word(w, &t) { 6 } else { 4 };
                } else if n.contains(w) {
                    score += if starts_word(w, &n) { 3 } else { 2 };
                } else if tags.iter().any(|tag| tag.contains(w))
                    || category.contains(w)
                    || title.contains(w)
                {
                    score += 1;
                } else {
                    all = false;
                    break;
                }
            }
            if !all {
                continue;
            }
            if words.len() > 1 {
                if h.contains(&phrase) {
                    score += 20;
                } else if t.contains(&phrase) || n.contains(&phrase) {
                    score += 10;
                }
            }
            // Where to show the match: the first field holding a word that isn't only in the deck title.
            let (field, source) = if words.iter().any(|w| h.contains(w))
                && !words
                    .iter()
                    .any(|w| !h.contains(w) && (t.contains(w) || n.contains(w)))
            {
                (
                    Field::Heading,
                    if s.text.is_empty() {
                        &s.heading
                    } else {
                        &s.text
                    },
                )
            } else if words.iter().any(|w| t.contains(w)) {
                (Field::Text, &s.text)
            } else if words.iter().any(|w| n.contains(w)) {
                (Field::Notes, &s.notes)
            } else {
                (Field::Heading, &s.text)
            };
            hits.push(Hit {
                deck: deck.source.clone(),
                deck_title: deck.title.clone(),
                slide: i,
                heading: if s.heading.is_empty() {
                    format!("Slide {}", i + 1)
                } else {
                    s.heading.clone()
                },
                field,
                snippet: snippet(source, &words, 140),
                score,
            });
        }
    }
    // Best first; ties keep deck and slide order (a stable sort).
    hits.sort_by_key(|h| std::cmp::Reverse(h.score));
    hits.truncate(limit);
    hits
}

/// `CharacterSet.whitespaces`: spaces and tabs, not line breaks.
fn trim_spaces(s: &str) -> &str {
    s.trim_matches(|c: char| {
        c.is_whitespace()
            && !matches!(
                c,
                '\n' | '\r' | '\u{b}' | '\u{c}' | '\u{85}' | '\u{2028}' | '\u{2029}'
            )
    })
}

/// About `width` characters of `text` around the first matching word, on word boundaries.
pub fn snippet(text: &str, words: &[&str], width: usize) -> String {
    let clean = trim(text);
    let chars: Vec<char> = clean.chars().collect();
    if chars.len() <= width {
        return clean.to_string();
    }
    let folded = fold(clean);
    // Folding keeps the length for nearly all text; fall back to the start if it doesn't.
    let hit = if folded.chars().count() == chars.len() {
        words
            .iter()
            .filter_map(|w| folded.find(w).map(|b| folded[..b].chars().count()))
            .min()
            .unwrap_or(0)
    } else {
        0
    };
    let mut start = hit.saturating_sub(width / 3);
    while start > 0 && !chars[start - 1].is_whitespace() {
        start -= 1;
    }
    let mut end = (start + width).min(chars.len());
    while end < chars.len() && !chars[end].is_whitespace() {
        end += 1;
    }
    let body: String = chars[start..end].iter().collect();
    format!(
        "{}{}{}",
        if start > 0 { "…" } else { "" },
        trim_spaces(&body),
        if end < chars.len() { "…" } else { "" }
    )
}
