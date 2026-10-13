//! Reads the fixtures the Swift tests write (docs/specs/fixtures).
#![allow(dead_code)]

use std::path::PathBuf;

pub fn dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../docs/specs/fixtures")
}

pub fn bytes(name: &str) -> Vec<u8> {
    std::fs::read(dir().join(name)).unwrap_or_else(|e| panic!("fixture {name}: {e}"))
}

pub fn text(name: &str) -> String {
    String::from_utf8(bytes(name)).expect("UTF-8 fixture")
}

pub fn json(name: &str) -> serde_json::Value {
    serde_json::from_slice(&bytes(name)).unwrap_or_else(|e| panic!("fixture {name}: {e}"))
}

pub fn s(v: &serde_json::Value) -> &str {
    v.as_str()
        .unwrap_or_else(|| panic!("expected a string, got {v}"))
}

pub fn opt_s(v: Option<&serde_json::Value>) -> Option<String> {
    v.and_then(|v| v.as_str()).map(str::to_string)
}

pub fn strings(v: &serde_json::Value) -> Vec<String> {
    v.as_array()
        .expect("array")
        .iter()
        .map(|x| s(x).to_string())
        .collect()
}

/// A first differing position, for readable failures on long text.
pub fn assert_same(name: &str, ours: &str, theirs: &str) {
    if ours != theirs {
        let at = ours
            .bytes()
            .zip(theirs.bytes())
            .position(|(a, b)| a != b)
            .unwrap_or(ours.len().min(theirs.len()));
        let lo = at.saturating_sub(80);
        panic!(
            "{name} differs at byte {at}:\n ours:   {:?}\n swift:  {:?}",
            ours.get(lo..(at + 80).min(ours.len())).unwrap_or(""),
            theirs.get(lo..(at + 80).min(theirs.len())).unwrap_or("")
        );
    }
}
