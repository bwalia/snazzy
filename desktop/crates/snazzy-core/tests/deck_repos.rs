//! docs/specs/deck-repos.md against the Swift fixtures.

mod common;

use common::{json, s, strings};
use serde_json::Value;
use snazzy_core::deck_repo::{self, Catalogue, DeckRepo, RemoteDeck, TreeEntry};

#[test]
fn parses_what_people_paste() {
    let cases = json("deck-repo-cases.json");
    assert_eq!(
        serde_json::from_value::<DeckRepo>(cases["official"].clone()).unwrap(),
        DeckRepo::official()
    );
    assert_eq!(s(&cases["catalogueFile"]), deck_repo::CATALOGUE_FILE);
    assert_eq!(
        strings(&cases["allowedExtensions"]),
        deck_repo::ALLOWED_EXTENSIONS
    );
    let limits = &cases["limits"];
    assert_eq!(
        limits["maxFilesPerDeck"].as_u64(),
        Some(deck_repo::MAX_FILES_PER_DECK as u64)
    );
    assert_eq!(
        limits["maxFileBytes"].as_u64(),
        Some(deck_repo::MAX_FILE_BYTES)
    );
    assert_eq!(
        limits["maxDeckBytes"].as_u64(),
        Some(deck_repo::MAX_DECK_BYTES)
    );
    assert_eq!(
        limits["maxDepth"].as_u64(),
        Some(deck_repo::MAX_DEPTH as u64)
    );

    for case in cases["parse"].as_array().unwrap() {
        let (input, expected) = case.as_object().unwrap().iter().next().unwrap();
        let parsed = DeckRepo::parse(input);
        if expected.is_null() {
            assert_eq!(parsed, None, "parse({input:?})");
            continue;
        }
        let r = parsed.unwrap_or_else(|| panic!("parse({input:?}) should succeed"));
        assert_eq!(r.owner, s(&expected["owner"]), "{input:?}");
        assert_eq!(r.repo, s(&expected["repo"]), "{input:?}");
        assert_eq!(
            r.branch.as_deref(),
            expected.get("branch").and_then(Value::as_str),
            "{input:?}"
        );
        assert_eq!(r.path, s(&expected["path"]), "{input:?}");
        assert_eq!(r.name(), s(&expected["name"]), "{input:?}");
        assert_eq!(r.id(), s(&expected["id"]), "{input:?}");
        assert_eq!(r.web_url(), s(&expected["webURL"]), "{input:?}");
        assert_eq!(r.repo_api(), s(&expected["repoAPI"]), "{input:?}");
        assert_eq!(
            r.tree_api("feature/a b"),
            s(&expected["treeAPI"]),
            "{input:?}"
        );
        assert_eq!(
            r.raw_url("main", "decks/my deck/index.html"),
            s(&expected["rawURL"]),
            "{input:?}"
        );
    }
    for c in cases["prettify"].as_array().unwrap() {
        assert_eq!(deck_repo::prettify(s(&c[0])), s(&c[1]));
    }
}

#[test]
fn finds_the_same_decks() {
    let cases = json("deck-repo-cases.json");
    for c in cases["decks"].as_array().unwrap() {
        let name = s(&c["name"]);
        let repo: DeckRepo = serde_json::from_value(c["repo"].clone()).unwrap();
        let tree: Vec<TreeEntry> = serde_json::from_value(c["tree"].clone()).unwrap();
        let catalogue: Option<Catalogue> = c
            .get("catalogue")
            .map(|v| serde_json::from_value(v.clone()).unwrap());
        let expected: Vec<RemoteDeck> = serde_json::from_value(c["decks"].clone()).unwrap();
        let found = deck_repo::decks(&repo, s(&c["branch"]), &tree, catalogue.as_ref());
        assert_eq!(found, expected, "{name}");
        assert_eq!(
            found.iter().map(RemoteDeck::origin).collect::<Vec<_>>(),
            strings(&c["origins"]),
            "{name}"
        );
        assert_eq!(
            found.iter().map(RemoteDeck::web_url).collect::<Vec<_>>(),
            strings(&c["webURLs"]),
            "{name}"
        );
        // And the JSON is the same both ways.
        assert_eq!(serde_json::to_value(&found).unwrap(), c["decks"], "{name}");
    }
}

#[test]
fn reads_github_tree_and_catalogue_json() {
    let (entries, truncated) =
        deck_repo::parse_tree(br#"{"sha":"x","tree":[{"path":"a/index.html","type":"blob","size":12,"mode":"100644"},{"path":"a","type":"tree"}],"truncated":true}"#)
            .unwrap();
    assert_eq!(entries.len(), 2);
    assert!(truncated);
    assert!(deck_repo::parse_catalogue(br#"{"decks":[{"path":"q4","tags":["Q4"]}]}"#).is_some());
    assert!(deck_repo::parse_catalogue(br#"{"title":"no decks"}"#).is_none());
}
