//! docs/specs/projects.md against the Swift fixtures.

mod common;

use common::{assert_same, bytes, json, opt_s, s, strings, text};
use snazzy_core::deck::DeckOutline;
use snazzy_core::iso8601::Date;
use snazzy_core::project::{BuilderProject, ProjectKind, clean_tags};
use snazzy_core::workspace::{MAX_FILE_BYTES, Workspace, slug};

#[test]
fn project_files_round_trip() {
    let full = BuilderProject::from_json(&bytes("project.json")).unwrap();
    assert_eq!(full.kind, ProjectKind::Presentation);
    assert!(full.is_shared());
    assert_eq!(full.created, Date::from_unix(1_767_323_045).unwrap());
    assert_same("project.json", &full.to_json(), &text("project.json"));

    let old = BuilderProject::from_json(&bytes("project-old.json")).unwrap();
    assert_eq!(
        (
            old.shared,
            old.category.as_deref(),
            old.tags.as_ref(),
            old.origin.as_deref()
        ),
        (None, None, None, None)
    );
    assert_same(
        "project-old.json",
        &old.to_json(),
        &text("project-old.json"),
    );
}

/// Characters the Mac transliterates with ICU (other scripts): not matched here.
fn latin_only(s: &str) -> bool {
    s.chars()
        .all(|c| (c as u32) < 0x370 || ((c as u32) >= 0x1E00 && (c as u32) < 0x1F00))
}

#[test]
fn workspace_rules_match() {
    let cases = json("workspace-cases.json");
    assert_eq!(cases["maxFileBytes"].as_u64(), Some(MAX_FILE_BYTES as u64));
    let mut checked = 0;
    for c in cases["slug"].as_array().unwrap() {
        let (input, expected) = (s(&c[0]), s(&c[1]));
        if latin_only(input) {
            assert_eq!(slug(input), expected, "slug({input:?})");
            checked += 1;
        } else {
            // Still a valid folder name.
            assert!(
                slug(input)
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || c == '-')
            );
        }
    }
    assert!(checked >= 12);
    for c in cases["cleanTags"].as_array().unwrap() {
        assert_eq!(clean_tags(&strings(&c[0])), strings(&c[1]));
    }

    let dir = tempfile::tempdir().unwrap();
    let ws = Workspace::new(dir.path());
    let p = ws
        .create_project("proj", ProjectKind::Presentation, None)
        .unwrap();
    assert_eq!(ws.files(&p.name), ["deck.css", "deck.js", "index.html"]);
    for c in cases["setDetails"].as_array().unwrap() {
        let tags = strings(&c["tags"]);
        let r = ws
            .set_details(
                &p.name,
                opt_s(c.get("category")).as_deref(),
                &tags,
                opt_s(c.get("origin")).as_deref(),
            )
            .unwrap();
        assert_eq!(r.category, opt_s(c.get("resultCategory")), "{c}");
        assert_eq!(r.tags, c.get("resultTags").map(strings), "{c}");
        assert_eq!(r.origin, opt_s(c.get("resultOrigin")), "{c}");
    }

    std::fs::create_dir_all(ws.project_dir(&p.name).join("real")).unwrap();
    #[cfg(unix)]
    std::os::unix::fs::symlink(
        ws.project_dir(&p.name).join("real"),
        ws.project_dir(&p.name).join("link"),
    )
    .unwrap();
    let root = ws.project_dir(&p.name);
    for c in cases["resolve"].as_array().unwrap() {
        let path = s(&c["path"]);
        if cfg!(not(unix)) && path.starts_with("link") {
            continue;
        }
        match ws.resolve(&p.name, path) {
            Ok(url) => {
                let rel = url
                    .strip_prefix(&root)
                    .unwrap()
                    .to_string_lossy()
                    .replace('\\', "/");
                assert_eq!(Some(rel), opt_s(c.get("resolved")), "resolve({path:?})");
            }
            Err(e) => assert_eq!(Some(e.0), opt_s(c.get("error")), "resolve({path:?})"),
        }
    }
    assert!(ws.write(&p.name, "big.txt", &"a".repeat(2_000_000)).is_ok());
    assert_eq!(
        ws.write(&p.name, "big.txt", &"a".repeat(2_000_001))
            .unwrap_err()
            .0,
        s(&cases["writeLimit"]["2000001"])
    );
}

#[test]
fn outlines_save_like_the_mac() {
    let dir = tempfile::tempdir().unwrap();
    let ws = Workspace::new(dir.path());
    let p = ws
        .create_project("Q3 review", ProjectKind::Presentation, None)
        .unwrap();
    assert_eq!(p.name, "q3-review");
    ws.delete(&p.name, "deck.css").unwrap();
    let outline = DeckOutline::from_json(&bytes("deck.json")).unwrap();
    ws.save_outline(&outline, &p.name, true).unwrap();
    assert_same(
        "deck.json",
        &ws.read(&p.name, "deck.json").unwrap(),
        &text("deck.json"),
    );
    assert_same(
        "index.html",
        &ws.read(&p.name, "index.html").unwrap(),
        &text("deck-outline.html"),
    );
    assert_same(
        "deck.css",
        &ws.read(&p.name, "deck.css").unwrap(),
        &text("deck.css"),
    );
    assert_eq!(ws.load_outline(&p.name), Some(outline));
    // Metadata is reserved and hidden from the file list.
    assert_eq!(
        ws.files(&p.name),
        ["deck.css", "deck.js", "deck.json", "index.html"]
    );
    assert!(ws.read(&p.name, ".snazzy-project.json").is_err());
    assert_eq!(ws.list_projects().len(), 1);
    // Creating again returns the same project.
    assert_eq!(
        ws.create_project("Q3 Review", ProjectKind::Prototype, None)
            .unwrap(),
        p
    );
    ws.set_shared(&p.name, true).unwrap();
    assert!(ws.project(&p.name).unwrap().is_shared());
    ws.set_shared(&p.name, false).unwrap();
    assert!(!text_of(&ws, &p.name).contains("shared"));
    ws.delete_project(&p.name).unwrap();
    assert!(ws.project(&p.name).is_none());
}

fn text_of(ws: &Workspace, name: &str) -> String {
    std::fs::read_to_string(ws.project_dir(name).join(".snazzy-project.json")).unwrap()
}
