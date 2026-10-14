//! The deck library's workspace operations: samples, slide-editor decks, sharing
//! and importing (Workspace.swift, SampleDecks.swift, DeckOutline.swift,
//! SnazzyShare.swift, DeckRepoCatalogue.project).

use snazzy_core::deck::{DeckOutline, OUTLINE_FILE};
use snazzy_core::deck_repo::{DeckRepo, RemoteDeck, project_for};
use snazzy_core::iso8601::Date;
use snazzy_core::project::ProjectKind;
use snazzy_core::samples;
use snazzy_core::search;
use snazzy_core::share::{self, Share};
use snazzy_core::workspace::Workspace;

fn workspace() -> (tempfile::TempDir, Workspace) {
    let dir = tempfile::tempdir().unwrap();
    let ws = Workspace::new(dir.path());
    (dir, ws)
}

#[test]
fn samples_open_as_editable_decks_in_their_sector() {
    let (_dir, ws) = workspace();
    let sample = &samples::all()[0];
    let p = ws.create_sample(sample).unwrap();
    assert_eq!(p.name, sample.project_name);
    assert_eq!(p.category.as_deref(), Some(sample.sector.as_str()));
    assert_eq!(p.tags, Some(vec!["Sample".to_string()]));
    assert!(!p.is_shared());
    assert_eq!(ws.read(&p.name, "index.html").unwrap(), sample.html());
    let outline = ws.load_outline(&p.name).unwrap();
    assert_eq!(outline.slides, sample.slides);
    assert_eq!(outline.accent, sample.accent);
    for f in ["deck.css", "deck.js", OUTLINE_FILE] {
        assert!(ws.files(&p.name).contains(&f.to_string()), "{f}");
    }
    // Opening it again keeps the copy (and any edits).
    ws.write(&p.name, "index.html", "edited").unwrap();
    ws.create_sample(sample).unwrap();
    assert_eq!(ws.read(&p.name, "index.html").unwrap(), "edited");

    // Search now finds the project, not the unopened sample.
    let decks = search::decks(&ws, samples::all());
    assert_eq!(decks.len(), samples::all().len());
    assert!(
        decks
            .iter()
            .any(|d| d.source == search::Source::Project(p.name.clone()))
    );
    assert!(
        !decks
            .iter()
            .any(|d| d.source == search::Source::Sample(sample.id.clone()))
    );
}

#[test]
fn editor_decks_get_free_names() {
    let (_dir, ws) = workspace();
    let outline = DeckOutline::starter("Q3 Review");
    let a = ws.create_deck(&outline).unwrap();
    let b = ws.create_deck(&outline).unwrap();
    assert_eq!(
        (a.name.as_str(), b.name.as_str()),
        ("q3-review", "q3-review-2")
    );
    assert_eq!(ws.read(&a.name, "index.html").unwrap(), outline.html());
    assert_eq!(ws.load_outline(&b.name), Some(outline));
    assert_eq!(a.kind, ProjectKind::Presentation);
}

#[test]
fn projects_round_trip_through_share_files() {
    let (_dir, ws) = workspace();
    ws.create_sample(&samples::all()[1]).unwrap();
    let name = samples::all()[1].project_name.clone();
    ws.write_bytes(&name, "img/pixel.png", &[0x89, b'P', b'N', b'G', 0, 255])
        .unwrap();
    let project = ws.share_project(&name).unwrap();
    assert!(project.files.iter().all(|f| !f.path.starts_with(".snazzy")));
    assert!(project.files.iter().any(|f| f.path == "img/pixel.png"));

    let share = Share::new(
        "Deck",
        "",
        Some(project.clone()),
        vec![],
        vec![],
        Date::now(),
    );
    let decoded = Share::decode(&share.encode().unwrap()).unwrap();
    let imported = ws
        .import_project(decoded.project.as_ref().unwrap())
        .unwrap();
    assert_eq!(imported.name, format!("{name}-2"));
    assert!(
        imported.is_shared(),
        "imports have no internet until allowed"
    );
    assert_eq!(
        imported.category, None,
        "details aren't carried in share files"
    );
    for f in &project.files {
        let path = ws.resolve(&imported.name, &f.path).unwrap();
        assert_eq!(std::fs::read(path).unwrap(), f.data, "{}", f.path);
    }
    assert_eq!(
        ws.import_project(&project).unwrap().name,
        format!("{name}-3")
    );
}

#[test]
fn bad_imports_leave_nothing_behind() {
    let (_dir, ws) = workspace();
    let project = share::Project {
        name: "Sneaky".into(),
        kind: ProjectKind::Presentation,
        files: vec![
            share::File {
                path: "index.html".into(),
                data: b"<p>hi".to_vec(),
            },
            share::File {
                path: "../outside.txt".into(),
                data: b"x".to_vec(),
            },
        ],
    };
    assert!(ws.import_project(&project).is_err());
    assert!(ws.list_projects().is_empty());
    assert!(!ws.root.join("sneaky").exists());
    assert!(!ws.root.join("outside.txt").exists());
}

#[test]
fn downloaded_decks_are_named_after_their_folder() {
    let deck = RemoteDeck {
        repo: DeckRepo::official(),
        branch: "main".into(),
        folder: "decks/build-ship-ai".into(),
        title: "Build, ship, AI".into(),
        description: String::new(),
        category: Some("Technology".into()),
        tags: vec![],
        author: None,
        files: vec!["index.html".into()],
        bytes: 5,
    };
    let p = project_for(&deck, vec![("index.html".into(), b"<p>hi".to_vec())]);
    assert_eq!(p.name, "build-ship-ai");
    assert_eq!(p.kind, ProjectKind::Presentation);
    assert_eq!(p.files[0].path, "index.html");
}
