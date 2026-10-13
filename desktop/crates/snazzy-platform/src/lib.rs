//! The thin per-platform layer: where things are stored, opening links and
//! folders, and secrets in the OS credential store. Everything else is shared
//! (docs/plans/PROMPT_WINDOWS_LINUX.md §2).

pub mod open;
pub mod paths;
pub mod secrets;
