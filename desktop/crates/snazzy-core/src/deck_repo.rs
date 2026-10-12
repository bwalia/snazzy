//! Deck repositories on GitHub (Builder/DeckRepo.swift, decks/README.md): what
//! people may paste, how deck folders are found, `snazzy-decks.json`, file limits.
//! Spec: docs/specs/deck-repos.md.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::project::clean_tags;
use crate::share::is_safe_relative_path;

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct DeckRepo {
    pub owner: String,
    pub repo: String,
    /// None means the repository's default branch.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
    /// Folder inside the repository ("" for the top).
    pub path: String,
}

pub const CATALOGUE_FILE: &str = "snazzy-decks.json";

impl DeckRepo {
    pub fn new(owner: &str, repo: &str, branch: Option<&str>, path: &str) -> Self {
        Self {
            owner: owner.into(),
            repo: repo.into(),
            branch: branch.map(Into::into),
            path: path.trim_matches('/').into(),
        }
    }

    /// Snazzy Pro's own deck collection.
    pub fn official() -> Self {
        Self::new("bwalia", "snazzy", None, "decks")
    }

    pub fn id(&self) -> String {
        self.name()
            + &self
                .branch
                .as_ref()
                .map(|b| format!("@{b}"))
                .unwrap_or_default()
    }

    /// "owner/repo" or "owner/repo/folder".
    pub fn name(&self) -> String {
        format!(
            "{}/{}{}",
            self.owner,
            self.repo,
            if self.path.is_empty() {
                String::new()
            } else {
                format!("/{}", self.path)
            }
        )
    }

    pub fn web_url(&self) -> String {
        let mut s = format!("https://github.com/{}/{}", self.owner, self.repo);
        if self.branch.is_some() || !self.path.is_empty() {
            s += &format!("/tree/{}", self.branch.as_deref().unwrap_or("HEAD"));
            if !self.path.is_empty() {
                s += &format!("/{}", self.path);
            }
        }
        s
    }

    /// GitHub API: the repository (for its default branch).
    pub fn repo_api(&self) -> String {
        format!("https://api.github.com/repos/{}/{}", self.owner, self.repo)
    }

    /// GitHub API: every file in the branch.
    pub fn tree_api(&self, branch: &str) -> String {
        format!(
            "https://api.github.com/repos/{}/{}/git/trees/{}?recursive=1",
            self.owner,
            self.repo,
            encode_path(branch)
        )
    }

    /// A file's raw contents; `path` is relative to the repository top.
    pub fn raw_url(&self, branch: &str, path: &str) -> String {
        format!(
            "https://raw.githubusercontent.com/{}/{}/{}/{}",
            self.owner,
            self.repo,
            encode_path(branch),
            encode_path(path)
        )
    }

    /// Reads what people paste: "owner/repo", "owner/repo/folder",
    /// "github.com/owner/repo", or "https://github.com/owner/repo/tree/main/decks".
    pub fn parse(text: &str) -> Option<DeckRepo> {
        let mut s = text.trim().to_string();
        for prefix in ["https://", "http://", "www."] {
            if s.to_lowercase().starts_with(prefix) {
                s = s.chars().skip(prefix.chars().count()).collect();
            }
        }
        if s.to_lowercase().starts_with("github.com/") {
            s = s.chars().skip("github.com/".len()).collect();
        }
        if let Some(stripped) = s.strip_suffix(".git") {
            s = stripped.to_string();
        }
        s = s.split(['?', '#']).next().unwrap_or("").to_string();
        let parts: Vec<&str> = s.split('/').filter(|p| !p.is_empty()).collect();
        // GitHub user and organisation names are letters, digits and dashes only.
        if parts.len() < 2
            || !valid(parts[1])
            || parts[0].chars().count() > 39
            || !parts[0]
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '-')
        {
            return None;
        }
        if parts.len() >= 4 && (parts[2] == "tree" || parts[2] == "blob") {
            let branch = parts[3];
            if !valid_path(branch) {
                return None;
            }
            let rest = parts[4..].join("/");
            if !rest.is_empty() && !valid_path(&rest) {
                return None;
            }
            return Some(DeckRepo::new(
                parts[0],
                parts[1],
                (branch != "HEAD").then_some(branch),
                &rest,
            ));
        }
        let rest = parts[2..].join("/");
        if !rest.is_empty() && !valid_path(&rest) {
            return None;
        }
        Some(DeckRepo::new(parts[0], parts[1], None, &rest))
    }
}

fn valid(s: &str) -> bool {
    !s.is_empty()
        && s.chars().count() <= 100
        && s != "."
        && s != ".."
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c))
}

fn valid_path(s: &str) -> bool {
    s.split('/').filter(|p| !p.is_empty()).all(valid)
}

/// Each component percent-encoded as `.urlPathAllowed` does (unreserved and
/// `!$&'()*+,;=:@` stay; everything else becomes %XX), joined with `/`.
pub fn encode_path(path: &str) -> String {
    path.split('/')
        .filter(|p| !p.is_empty())
        .map(|p| {
            let mut out = String::new();
            for b in p.bytes() {
                if b.is_ascii_alphanumeric() || b"-._~!$&'()*+,;=:@".contains(&b) {
                    out.push(b as char);
                } else {
                    out.push_str(&format!("%{b:02X}"));
                }
            }
            out
        })
        .collect::<Vec<_>>()
        .join("/")
}

/// A deck found in a repo, ready to add.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RemoteDeck {
    pub repo: DeckRepo,
    pub branch: String,
    /// The deck's folder, relative to the repository top.
    pub folder: String,
    pub title: String,
    pub description: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub category: Option<String>,
    pub tags: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author: Option<String>,
    /// Files to download, relative to `folder`.
    pub files: Vec<String>,
    pub bytes: u64,
}

impl RemoteDeck {
    pub fn id(&self) -> String {
        format!("{}/{}/{}", self.repo.owner, self.repo.repo, self.folder)
    }

    /// Stored on the project, so the library knows it's already added.
    pub fn origin(&self) -> String {
        format!(
            "github:{}/{}/{}",
            self.repo.owner, self.repo.repo, self.folder
        )
    }

    pub fn web_url(&self) -> String {
        format!(
            "https://github.com/{}/{}/tree/{}/{}",
            self.repo.owner,
            self.repo.repo,
            encode_path(&self.branch),
            encode_path(&self.folder)
        )
    }

    /// The project name an import starts from (the folder's last part).
    pub fn project_name(&self) -> String {
        self.folder
            .split('/')
            .rfind(|p| !p.is_empty())
            .map_or_else(|| self.title.clone(), str::to_string)
    }
}

/// What `snazzy-decks.json` may say. Everything but `path` is optional.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Catalogue {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    pub decks: Vec<CatalogueEntry>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CatalogueEntry {
    pub path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub category: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tags: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author: Option<String>,
}

/// One file in a GitHub tree listing.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TreeEntry {
    pub path: String,
    #[serde(rename = "type")]
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub size: Option<u64>,
}

// Limits for a deck from someone else: web files only, nothing huge.
pub const ALLOWED_EXTENSIONS: [&str; 23] = [
    "avif", "css", "gif", "htm", "html", "jpeg", "jpg", "js", "json", "m4a", "md", "mp3", "mp4",
    "otf", "png", "svg", "ttf", "txt", "vtt", "webm", "webp", "woff", "woff2",
];
pub const MAX_FILES_PER_DECK: usize = 80;
pub const MAX_FILE_BYTES: u64 = crate::workspace::MAX_FILE_BYTES as u64;
pub const MAX_DECK_BYTES: u64 = 40_000_000;
/// Decks deeper than this under the repo folder aren't looked for.
pub const MAX_DEPTH: usize = 3;

/// The GitHub tree API response's entries, and whether GitHub cut the list short.
pub fn parse_tree(data: &[u8]) -> serde_json::Result<(Vec<TreeEntry>, bool)> {
    #[derive(Deserialize)]
    struct Response {
        tree: Vec<TreeEntry>,
        truncated: Option<bool>,
    }
    let r: Response = serde_json::from_slice(data)?;
    Ok((r.tree, r.truncated.unwrap_or(false)))
}

pub fn parse_catalogue(data: &[u8]) -> Option<Catalogue> {
    serde_json::from_slice(data).ok()
}

fn clean(path: &str) -> &str {
    path.trim_matches(['/', ' '])
}

fn extension(path: &str) -> String {
    // NSString.pathExtension: of the last component, not counting a leading dot.
    let last = path.rsplit('/').next().unwrap_or("");
    match last.rfind('.') {
        Some(i) if i > 0 => last[i + 1..].to_lowercase(),
        _ => String::new(),
    }
}

/// "build-ship-ai" → "Build ship ai"; "q3_results" → "Q3 results".
pub fn prettify(s: &str) -> String {
    let replaced = s.replace(['_', '-'], " ");
    let words: Vec<&str> = replaced.split(' ').filter(|w| !w.is_empty()).collect();
    let Some(first) = words.first() else {
        return s.to_string();
    };
    let mut chars = first.chars();
    let head: String = chars
        .next()
        .map(|c| c.to_uppercase().collect())
        .unwrap_or_default();
    std::iter::once(head + chars.as_str())
        .chain(words[1..].iter().map(|w| w.to_string()))
        .collect::<Vec<_>>()
        .join(" ")
}

/// The decks in a repo folder: every folder (up to `MAX_DEPTH` down) with an
/// index.html, described by the catalogue where it has an entry. Catalogue order
/// first, then the rest by title.
pub fn decks(
    repo: &DeckRepo,
    branch: &str,
    tree: &[TreeEntry],
    catalogue: Option<&Catalogue>,
) -> Vec<RemoteDeck> {
    let base = if repo.path.is_empty() {
        String::new()
    } else {
        format!("{}/", repo.path)
    };
    let blobs: Vec<&TreeEntry> = tree
        .iter()
        .filter(|e| e.kind == "blob" && e.path.starts_with(&base))
        .collect();
    let mut folders: Vec<String> = Vec::new();
    for b in &blobs {
        let rel = &b.path[base.len()..];
        if !(rel.ends_with("/index.html") || rel == "index.html") {
            continue;
        }
        let folder = if rel == "index.html" {
            ""
        } else {
            &rel[..rel.len() - "/index.html".len()]
        };
        let parts: Vec<&str> = folder.split('/').filter(|p| !p.is_empty()).collect();
        if parts.len() > MAX_DEPTH || parts.iter().any(|p| p.starts_with('.')) {
            continue;
        }
        folders.push(folder.to_string());
    }
    // A deck folder never contains another deck: skip folders inside one already found.
    folders.sort_by_key(|f| f.chars().count());
    let mut deck_folders: Vec<String> = Vec::new();
    for f in folders {
        if !deck_folders.iter().any(|d| {
            if d.is_empty() {
                !f.is_empty()
            } else {
                f.starts_with(&format!("{d}/"))
            }
        }) {
            deck_folders.push(f);
        }
    }
    // With decks in subfolders, a top-level index.html is the repo's own page, not a deck.
    if deck_folders.len() > 1 {
        deck_folders.retain(|f| !f.is_empty());
    }

    let mut entries: HashMap<&str, &CatalogueEntry> = HashMap::new();
    let mut order: HashMap<&str, usize> = HashMap::new();
    for (i, e) in catalogue
        .map(|c| c.decks.as_slice())
        .unwrap_or_default()
        .iter()
        .enumerate()
    {
        entries.entry(clean(&e.path)).or_insert(e);
        order.entry(clean(&e.path)).or_insert(i);
    }
    let mut out: Vec<RemoteDeck> = Vec::new();
    for folder in &deck_folders {
        let full = format!("{base}{folder}");
        let prefix = if folder.is_empty() {
            base.clone()
        } else {
            format!("{full}/")
        };
        let files: Vec<(String, u64)> = blobs
            .iter()
            .filter(|b| b.path.starts_with(&prefix))
            .filter_map(|b| {
                let rel = &b.path[prefix.len()..];
                let ok = is_safe_relative_path(rel)
                    && !rel.split('/').any(|p| p.starts_with('.'))
                    && ALLOWED_EXTENSIONS.contains(&extension(rel).as_str())
                    && b.size.unwrap_or(0) <= MAX_FILE_BYTES;
                ok.then(|| (rel.to_string(), b.size.unwrap_or(0)))
            })
            .collect();
        if !files.iter().any(|(p, _)| p == "index.html") || files.len() > MAX_FILES_PER_DECK {
            continue;
        }
        let bytes: u64 = files.iter().map(|(_, s)| s).sum();
        if bytes > MAX_DECK_BYTES {
            continue;
        }
        let entry = entries.get(folder.as_str());
        let parts: Vec<&str> = folder.split('/').filter(|p| !p.is_empty()).collect();
        let title = entry
            .and_then(|e| e.title.clone())
            .unwrap_or_else(|| prettify(parts.last().copied().unwrap_or(&repo.repo)));
        // Folder layout "education/photosynthesis" gives the category "Education".
        let category = entry
            .and_then(|e| e.category.clone())
            .or_else(|| (parts.len() >= 2).then(|| prettify(parts[parts.len() - 2])));
        let mut names: Vec<String> = files.into_iter().map(|(p, _)| p).collect();
        names.sort();
        out.push(RemoteDeck {
            repo: repo.clone(),
            branch: branch.into(),
            folder: full.trim_matches('/').into(),
            title,
            description: entry
                .and_then(|e| e.description.clone())
                .unwrap_or_default(),
            category,
            tags: clean_tags(entry.and_then(|e| e.tags.as_deref()).unwrap_or_default()),
            author: entry.and_then(|e| e.author.clone()),
            files: names,
            bytes,
        });
    }
    let relative = |folder: &str| -> String {
        if base.is_empty() {
            folder.to_string()
        } else {
            folder
                .chars()
                .skip(base.chars().count().min(folder.chars().count()))
                .collect()
        }
    };
    out.sort_by(|a, b| {
        let ra = order
            .get(relative(&a.folder).as_str())
            .copied()
            .unwrap_or(usize::MAX);
        let rb = order
            .get(relative(&b.folder).as_str())
            .copied()
            .unwrap_or(usize::MAX);
        // The Mac compares titles with localizedCaseInsensitiveCompare; this folds case only.
        ra.cmp(&rb)
            .then_with(|| a.title.to_lowercase().cmp(&b.title.to_lowercase()))
    });
    out
}
