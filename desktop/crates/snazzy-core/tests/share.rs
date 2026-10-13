//! docs/specs/share.md against the Swift fixtures.

mod common;

use common::{assert_same, bytes, json, s, text};
use snazzy_core::share::{self, Share};

#[test]
fn opens_mac_share_files() {
    let shared = Share::decode(&bytes("share-basic.snazzy")).unwrap();
    let project = shared.project.as_ref().unwrap();
    assert_eq!(project.files.len(), 2);
    assert_eq!(project.files[1].path, "img/logo.png");
    assert_eq!(project.files[1].data[..4], [0x89, b'P', b'N', b'G']);
    assert_eq!(shared.created.format(), "2026-01-02T03:04:05Z");
    // The JSON inside, re-encoded here, is byte for byte what the Mac wrote.
    let inner =
        share::inflate(&bytes("share-basic.snazzy")[8..], share::MAX_EXPANDED_BYTES).unwrap();
    assert_eq!(inner, bytes("share-basic.json"));
    assert_same(
        "share-basic.json",
        &String::from_utf8(shared.to_json().unwrap()).unwrap(),
        &text("share-basic.json"),
    );

    let empty = Share::decode(&bytes("share-empty.snazzy")).unwrap();
    assert!(empty.is_empty());
    assert_same(
        "share-empty.json",
        &String::from_utf8(empty.to_json().unwrap()).unwrap(),
        &text("share-empty.json"),
    );

    // Presets reference background images by ID.
    assert_eq!(
        share::image_ids(&shared.presets[0])
            .into_iter()
            .collect::<Vec<_>>(),
        json("share-cases.json")["imageIDs"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| s(v).to_string())
            .collect::<Vec<_>>()
    );
    let remapped = share::remap_images(
        &shared.presets[0],
        &[("bg-1".to_string(), "bg-9".to_string())].into(),
    );
    assert_eq!(
        share::image_ids(&remapped).into_iter().collect::<Vec<_>>(),
        ["bg-9"]
    );
}

#[test]
fn writes_files_the_mac_opens() {
    let shared = Share::decode(&bytes("share-basic.snazzy")).unwrap();
    let ours = shared.encode().unwrap();
    assert_eq!(&ours[..8], b"SNZSHR01");
    assert_eq!(Share::decode(&ours).unwrap(), shared);
    // For the Swift test (SpecFixtureTests.shareFiles) to open: written on request only.
    if std::env::var("SNAZZY_WRITE_FIXTURES").as_deref() == Ok("1") {
        std::fs::write(common::dir().join("share-from-rust.snazzy"), &ours).unwrap();
    }
}

#[test]
fn refuses_what_the_mac_refuses() {
    let cases = json("share-cases.json");
    let limits = &cases["limits"];
    assert_eq!(
        limits["maxCompressedBytes"].as_u64(),
        Some(share::MAX_COMPRESSED_BYTES as u64)
    );
    assert_eq!(
        limits["maxExpandedBytes"].as_u64(),
        Some(share::MAX_EXPANDED_BYTES as u64)
    );
    assert_eq!(limits["maxFiles"].as_u64(), Some(share::MAX_FILES as u64));
    assert_eq!(
        limits["maxFileBytes"].as_u64(),
        Some(share::MAX_FILE_BYTES as u64)
    );
    assert_eq!(limits["maxImages"].as_u64(), Some(share::MAX_IMAGES as u64));
    assert_eq!(
        limits["maxPresets"].as_u64(),
        Some(share::MAX_PRESETS as u64)
    );
    assert_eq!(limits["version"].as_i64(), Some(share::VERSION));
    for c in cases["cases"].as_array().unwrap() {
        let data = snazzy_core::b64::decode(s(&c["file"])).unwrap();
        let result = Share::decode(&data).map(|_| ()).map_err(|e| e.0);
        let expected = c.get("error").map(|e| s(e).to_string());
        assert_eq!(result.err(), expected, "{}", s(&c["name"]));
    }
    for (path, safe) in cases["safePaths"].as_object().unwrap() {
        assert_eq!(
            share::is_safe_relative_path(path),
            safe.as_bool().unwrap(),
            "{path:?}"
        );
    }
}
