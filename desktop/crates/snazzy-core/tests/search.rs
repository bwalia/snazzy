//! docs/specs/search.md against the Swift fixtures.

mod common;

use common::{json, opt_s, s, strings, text};
use serde_json::Value;
use snazzy_core::fold::fold;
use snazzy_core::search::{self, Deck, Slide, Source};

fn slide(v: &Value) -> Slide {
    Slide {
        heading: s(&v["heading"]).into(),
        text: s(&v["text"]).into(),
        notes: s(&v["notes"]).into(),
    }
}

fn deck(v: &Value) -> Deck {
    let source = match opt_s(v.get("project")) {
        Some(p) => Source::Project(p),
        None => Source::Sample(s(&v["sample"]).into()),
    };
    Deck {
        source,
        title: s(&v["title"]).into(),
        category: opt_s(v.get("category")),
        tags: strings(&v["tags"]),
        slides: v["slides"].as_array().unwrap().iter().map(slide).collect(),
        created: None,
    }
}

#[test]
fn same_hits_scores_and_snippets() {
    let cases = json("search-cases.json");
    let decks: Vec<Deck> = cases["decks"]
        .as_array()
        .unwrap()
        .iter()
        .map(deck)
        .collect();
    // The fixture's sample decks are what the app builds from samples.json.
    let samples: Vec<Deck> = snazzy_core::samples::all()
        .iter()
        .map(search::sample_deck)
        .collect();
    assert_eq!(&decks[2..], &samples[..]);
    for q in cases["queries"].as_array().unwrap() {
        let query = s(&q["query"]);
        let limit = q.get("limit").and_then(Value::as_u64).unwrap_or(200) as usize;
        let hits = search::search(query, &decks, limit);
        let expected = q["hits"].as_array().unwrap();
        assert_eq!(hits.len(), expected.len(), "query {query:?}");
        for (h, e) in hits.iter().zip(expected) {
            let source = match &h.deck {
                Source::Project(p) => ("project", p),
                Source::Sample(p) => ("sample", p),
            };
            let ctx = format!("query {query:?}, {source:?} slide {}", h.slide);
            assert_eq!(Some(source.1.clone()), opt_s(e.get(source.0)), "{ctx}");
            assert_eq!(h.slide as u64, e["slide"].as_u64().unwrap(), "{ctx}");
            assert_eq!(h.deck_title, s(&e["deckTitle"]), "{ctx}");
            assert_eq!(h.heading, s(&e["heading"]), "{ctx}");
            assert_eq!(h.field.raw(), s(&e["field"]), "{ctx}");
            assert_eq!(h.score, e["score"].as_i64().unwrap(), "{ctx}");
            assert_eq!(h.snippet, s(&e["snippet"]), "{ctx}");
        }
    }
}

#[test]
fn same_slides_from_html() {
    let cases = json("search-cases.json");
    for c in cases["html"].as_array().unwrap() {
        let name = s(&c["name"]);
        let html = if name.ends_with(".html") {
            text(name)
        } else {
            s(&c["html"]).to_string()
        };
        let slides: Vec<Slide> = c["slides"].as_array().unwrap().iter().map(slide).collect();
        assert_eq!(search::slides_from_html(&html), slides, "{name}");
        assert_eq!(
            search::title_from_html(&html),
            opt_s(c.get("title")),
            "{name}"
        );
    }
    for c in cases["plain"].as_array().unwrap() {
        assert_eq!(search::plain(s(&c[0])), s(&c[1]), "plain({:?})", s(&c[0]));
    }
}

#[test]
fn same_snippets_and_folding() {
    let cases = json("search-cases.json");
    for c in cases["snippets"].as_array().unwrap() {
        let words = strings(&c["words"]);
        let words: Vec<&str> = words.iter().map(String::as_str).collect();
        let width = c["width"].as_u64().unwrap() as usize;
        assert_eq!(
            search::snippet(s(&c["text"]), &words, width),
            s(&c["snippet"]),
            "{words:?}"
        );
    }
    for c in cases["fold"].as_array().unwrap() {
        assert_eq!(fold(s(&c[0])), s(&c[1]), "fold({:?})", s(&c[0]));
    }
}

#[test]
fn workspace_decks_include_projects_and_unopened_samples() {
    let dir = tempfile::tempdir().unwrap();
    let ws = snazzy_core::workspace::Workspace::new(dir.path());
    let sample = snazzy_core::samples::get("lesson-photosynthesis").unwrap();
    let p = ws
        .create_project(
            &sample.project_name,
            snazzy_core::project::ProjectKind::Presentation,
            Some(&sample.title),
        )
        .unwrap();
    for (path, content) in sample.files() {
        ws.write(&p.name, path, &content).unwrap();
    }
    let decks = search::decks(&ws, snazzy_core::samples::all());
    assert_eq!(decks.len(), snazzy_core::samples::all().len());
    let opened = &decks[0];
    assert_eq!(
        opened.source,
        Source::Project("sample-lesson-photosynthesis".into())
    );
    assert_eq!(opened.category.as_deref(), Some("Education"));
    assert_eq!(opened.slides.len(), sample.slides.len());
    assert!(
        !decks
            .iter()
            .any(|d| d.source == Source::Sample("lesson-photosynthesis".into()))
    );
}
