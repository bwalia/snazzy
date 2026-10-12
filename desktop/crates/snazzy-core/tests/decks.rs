//! docs/specs/decks.md against the Swift fixtures.

mod common;

use common::{assert_same, bytes, json, s, text};
use snazzy_core::deck::{DeckOutline, Layout, template_files};
use snazzy_core::project::ProjectKind;
use snazzy_core::samples;

#[test]
fn samples_are_the_macs() {
    let all = samples::all();
    assert_eq!(all.len(), 13);
    assert_eq!(samples::sectors().len(), 12);
    // Every sample slide has notes rules on the Mac; here: every deck has slides and a project name.
    for s in all {
        assert!(!s.slides.is_empty(), "{}", s.id);
        assert_eq!(s.project_name, format!("sample-{}", s.id));
    }
    // Re-encoding gives the same JSON (so nothing is lost in the Rust types).
    let ours = snazzy_core::json::to_string(all, snazzy_core::json::Style::PRETTY_UNESCAPED)
        .unwrap()
        + "\n";
    assert_same("samples.json", &ours, &text("samples.json"));
}

#[test]
fn sample_pages_are_byte_identical() {
    for id in ["lesson-photosynthesis", "board-results", "build-ship-ai"] {
        let sample = samples::get(id).unwrap();
        assert_same(id, &sample.html(), &text(&format!("deck-{id}.html")));
        let files = sample.files();
        assert_eq!(
            files.iter().map(|f| f.0).collect::<Vec<_>>(),
            ["index.html", "deck.css", "deck.js"]
        );
    }
}

#[test]
fn templates_are_byte_identical() {
    let cases = json("templates.json");
    let title = s(&cases["title"]);
    let presentation = template_files(ProjectKind::Presentation, title);
    assert_eq!(
        presentation
            .iter()
            .map(|f| f.0)
            .collect::<Vec<_>>()
            .join(","),
        s(&cases["presentation"])
    );
    for (path, content) in &presentation {
        let fixture = if *path == "index.html" {
            "template-presentation-index.html".to_string()
        } else {
            path.to_string()
        };
        assert_same(path, content, &text(&fixture));
    }
    let prototype = template_files(ProjectKind::Prototype, title);
    assert_eq!(
        prototype.iter().map(|f| f.0).collect::<Vec<_>>().join(","),
        s(&cases["prototype"])
    );
    for (path, content) in &prototype {
        assert_same(path, content, &text(&format!("template-prototype-{path}")));
    }
    // The deck contract the Present window, remote and chapters rely on.
    let js = &presentation[2].1;
    assert!(js.contains(
        "window.snazzyDeck = { show, count: () => slides.length, current: () => current };"
    ));
    assert!(
        presentation[0]
            .1
            .contains("<section class=\"slide title\">")
    );
    assert!(presentation[0].1.contains("<aside class=\"notes\">"));
}

#[test]
fn deck_json_round_trips_byte_for_byte() {
    let fixture = bytes("deck.json");
    let outline = DeckOutline::from_json(&fixture).expect("deck.json decodes");
    assert_same("deck.json", &outline.to_json(), &text("deck.json"));
    assert_same(
        "deck-outline.html",
        &outline.html(),
        &text("deck-outline.html"),
    );
    // Every layout is in the fixture.
    for layout in Layout::ALL {
        assert!(
            outline.slides.iter().any(|s| s.layout == layout),
            "{layout:?}"
        );
    }
    let starter: DeckOutline = serde_json::from_slice(&bytes("deck-starter.json")).unwrap();
    assert_eq!(starter, DeckOutline::starter("New deck"));
}

#[test]
fn deck_json_needs_every_field() {
    assert!(DeckOutline::from_json(br##"{"title":"x","accent":"#fff","slides":[{"layout":"title","heading":"h","items":[]}]}"##).is_none());
    assert!(DeckOutline::from_json(br##"{"title":"x","accent":"#fff","slides":[{"layout":"poster","heading":"h","items":[],"notes":""}]}"##).is_none());
    assert!(
        DeckOutline::from_json(br##"{"title":"x","accent":"#fff","slides":[],"extra":1}"##)
            .is_some()
    );
}
