//! The formats Snazzy Pro shares with the Mac app. Each module follows a spec in
//! `docs/specs/` and is tested against fixtures the Swift code generates
//! (`docs/specs/fixtures/`), so a change on either side fails a test.

pub mod b64;
pub mod deck;
pub mod deck_repo;
pub mod fold;
mod fold_table;
pub mod iso8601;
pub mod json;
pub mod project;
pub mod samples;
pub mod search;
pub mod settings;
pub mod share;
pub mod timeline;
pub mod workspace;

/// A problem with a project, a path or a file, in words for the user (the same
/// messages as the Mac app's `WorkspaceError`).
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("{0}")]
pub struct WorkspaceError(pub String);

impl WorkspaceError {
    pub fn new(message: impl Into<String>) -> Self {
        Self(message.into())
    }
}
