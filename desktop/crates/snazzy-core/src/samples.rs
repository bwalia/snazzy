//! The sample decks for 12 sectors (Builder/SampleDecks.swift). Not re-typed: the
//! app embeds `docs/specs/fixtures/samples.json`, which the Swift tests generate
//! from `SampleDeck.all`. Spec: docs/specs/decks.md.

use std::sync::OnceLock;

use serde::{Deserialize, Serialize};

use crate::deck::{self, Slide};
use crate::project::ProjectKind;

const SAMPLES_JSON: &str = include_str!("../../../../docs/specs/fixtures/samples.json");

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SampleDeck {
    pub id: String,
    /// The sector's display name ("Education", "HR & People", …): also the
    /// category of an opened sample.
    pub sector: String,
    pub title: String,
    /// What the video is for, in one line.
    pub use_case: String,
    pub audience: String,
    pub minutes: u32,
    /// How to set up the recording.
    pub setup: Vec<String>,
    /// What to ask the assistant to get a deck like this.
    pub prompt: String,
    pub accent: String,
    pub slides: Vec<Slide>,
    /// Folder name when opened: `sample-<id>`.
    pub project_name: String,
}

impl SampleDeck {
    /// index.html, exactly as the Mac writes it.
    pub fn html(&self) -> String {
        let comment = format!(
            "Sample deck ({}). All names and figures are made up.",
            self.sector
        );
        deck::deck_html(&self.title, &self.accent, &self.slides, Some(&comment))
    }

    /// The project files: index.html plus the standard deck.css and deck.js.
    pub fn files(&self) -> Vec<(&'static str, String)> {
        let mut files = vec![("index.html", self.html())];
        files.extend(
            deck::template_files(ProjectKind::Presentation, &self.title)
                .into_iter()
                .filter(|(p, _)| *p != "index.html"),
        );
        files
    }
}

/// Every sample, in the Mac's order.
pub fn all() -> &'static [SampleDeck] {
    static ALL: OnceLock<Vec<SampleDeck>> = OnceLock::new();
    ALL.get_or_init(|| {
        serde_json::from_str(SAMPLES_JSON).expect("docs/specs/fixtures/samples.json is valid")
    })
}

pub fn get(id: &str) -> Option<&'static SampleDeck> {
    all().iter().find(|s| s.id == id)
}

/// The sectors, in the Mac's order.
pub fn sectors() -> Vec<&'static str> {
    let mut out: Vec<&str> = Vec::new();
    for s in all() {
        if !out.contains(&s.sector.as_str()) {
            out.push(&s.sector);
        }
    }
    out
}
