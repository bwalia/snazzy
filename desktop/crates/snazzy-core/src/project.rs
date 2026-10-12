//! `.snazzy-project.json`: a project's metadata (Builder/Workspace.swift,
//! `BuilderProject`). Spec: docs/specs/projects.md.

use serde::{Deserialize, Serialize};

use crate::iso8601::Date;
use crate::json;

pub const METADATA_FILE: &str = ".snazzy-project.json";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ProjectKind {
    /// An interactive app prototype (HTML/CSS/JS).
    Prototype,
    /// A presentation as an HTML slide deck.
    Presentation,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct BuilderProject {
    /// The folder name (a slug), also the host in `snazzy-project://<name>/`.
    pub name: String,
    pub kind: ProjectKind,
    pub created: Date,
    /// Came from someone else (.snazzy file, deck repo): no internet until allowed.
    /// Written only when true.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shared: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub category: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tags: Option<Vec<String>>,
    /// Where it was added from, e.g. "github:owner/repo/decks/name".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub origin: Option<String>,
}

impl BuilderProject {
    pub fn new(name: impl Into<String>, kind: ProjectKind, created: Date) -> Self {
        Self {
            name: name.into(),
            kind,
            created,
            shared: None,
            category: None,
            tags: None,
            origin: None,
        }
    }

    pub fn is_shared(&self) -> bool {
        self.shared == Some(true)
    }

    /// The file as the Mac writes it (`JSONEncoder.iso`: pretty, sorted, ISO dates).
    pub fn to_json(&self) -> String {
        json::to_string(self, json::Style::PRETTY).unwrap_or_default()
    }

    pub fn from_json(data: &[u8]) -> Option<Self> {
        serde_json::from_slice(data).ok()
    }

    /// Lets a shared project reach the internet, or takes that away (`setShared`).
    pub fn set_shared(&mut self, shared: bool) {
        self.shared = shared.then_some(true);
    }

    /// `Workspace.setDetails`: category trimmed and cut to 60 characters (blank
    /// removes it), tags cleaned and cut to 40 characters each and 20 in all
    /// (none removes them), origin replaced only when given.
    pub fn set_details(&mut self, category: Option<&str>, tags: &[String], origin: Option<&str>) {
        if let Some(origin) = origin {
            self.origin = Some(origin.to_string());
        }
        let c = category.map(trim).unwrap_or_default();
        self.category = (!c.is_empty()).then(|| prefix(c, 60));
        let t: Vec<String> = clean_tags(tags)
            .iter()
            .map(|t| prefix(t, 40))
            .take(20)
            .collect();
        self.tags = (!t.is_empty()).then_some(t);
    }
}

/// Tags without blanks, `#`s or repeats (ignoring case), in the order given.
pub fn clean_tags(tags: &[String]) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    tags.iter()
        .map(|t| trim(t).replace('#', ""))
        .filter(|t| !t.is_empty() && seen.insert(t.to_lowercase()))
        .collect()
}

/// `trimmingCharacters(in: .whitespacesAndNewlines)`.
pub fn trim(s: &str) -> &str {
    s.trim_matches(|c: char| c.is_whitespace())
}

/// The first `n` characters (Swift counts grapheme clusters; this counts
/// characters, the same for text without combining sequences).
pub fn prefix(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}
