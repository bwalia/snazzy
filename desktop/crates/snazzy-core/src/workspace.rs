//! Project folders (Builder/Workspace.swift): folder names, path confinement,
//! the 2 MB file limit. Spec: docs/specs/projects.md.

use std::fs;
use std::path::{Component, Path, PathBuf};

use crate::WorkspaceError;
use crate::deck::{DeckOutline, OUTLINE_FILE, template_files};
use crate::fold;
use crate::iso8601::Date;
use crate::project::{BuilderProject, METADATA_FILE, ProjectKind, trim};
use crate::samples::SampleDeck;
use crate::share;

/// Largest file the workspace reads or writes (the assistant's context would flood).
pub const MAX_FILE_BYTES: usize = 2_000_000;

/// Lower-case, dash-separated ASCII folder name, at most 60 characters, "project"
/// when nothing is left. Also the host of `snazzy-project://<slug>/`.
///
/// The Mac transliterates every script with ICU (`日本` → `ri-ben`); this strips
/// accents from Latin, Greek and Cyrillic letters only, so names in other scripts
/// give different (but still valid) folder names. See docs/specs/projects.md.
pub fn slug(name: &str) -> String {
    let latin = fold::strip_marks(name).to_lowercase();
    let parts: Vec<&str> = latin
        .split(|c: char| !c.is_ascii_alphanumeric())
        .filter(|p| !p.is_empty())
        .collect();
    let slug = parts.join("-");
    if slug.is_empty() {
        "project".into()
    } else {
        slug.chars().take(60).collect()
    }
}

/// Projects, one folder each, inside a root folder. Nothing outside a project can
/// be read or written through it.
#[derive(Debug, Clone)]
pub struct Workspace {
    pub root: PathBuf,
}

const RELATIVE_ONLY: &str =
    "Use a relative path inside the project, like \"index.html\" or \"js/app.js\".";

impl Workspace {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    pub fn project_dir(&self, name: &str) -> PathBuf {
        self.root.join(slug(name))
    }

    /// The project's metadata (None if there's no such project).
    pub fn project(&self, name: &str) -> Option<BuilderProject> {
        fs::read(self.project_dir(name).join(METADATA_FILE))
            .ok()
            .and_then(|d| BuilderProject::from_json(&d))
    }

    fn save_project(&self, p: &BuilderProject) -> Result<(), WorkspaceError> {
        fs::write(self.project_dir(&p.name).join(METADATA_FILE), p.to_json()).map_err(io)
    }

    /// Newest first.
    pub fn list_projects(&self) -> Vec<BuilderProject> {
        let mut out: Vec<BuilderProject> = fs::read_dir(&self.root)
            .map(|dirs| {
                dirs.flatten()
                    .filter_map(|d| fs::read(d.path().join(METADATA_FILE)).ok())
                    .filter_map(|data| BuilderProject::from_json(&data))
                    .collect()
            })
            .unwrap_or_default();
        out.sort_by_key(|p| std::cmp::Reverse(p.created));
        out
    }

    /// Creates a project with starter files, or returns the existing one.
    pub fn create_project(
        &self,
        name: &str,
        kind: ProjectKind,
        title: Option<&str>,
    ) -> Result<BuilderProject, WorkspaceError> {
        let slug = slug(name);
        if let Some(existing) = self.project(&slug) {
            return Ok(existing);
        }
        fs::create_dir_all(self.project_dir(&slug)).map_err(io)?;
        let project = BuilderProject::new(slug.clone(), kind, Date::now());
        self.save_project(&project)?;
        for (path, content) in template_files(kind, title.unwrap_or(name)) {
            self.write(&slug, path, &content)?;
        }
        Ok(project)
    }

    pub fn delete_project(&self, name: &str) -> Result<(), WorkspaceError> {
        let dir = self.project_dir(name);
        if !dir.exists() {
            return Err(WorkspaceError::new(format!("No project named {name}")));
        }
        fs::remove_dir_all(dir).map_err(io)
    }

    pub fn set_shared(&self, name: &str, shared: bool) -> Result<(), WorkspaceError> {
        let mut p = self
            .project(name)
            .ok_or_else(|| WorkspaceError::new(format!("No project \"{name}\".")))?;
        p.set_shared(shared);
        self.save_project(&p)
    }

    /// Category and tags (blank or empty removes them); see `BuilderProject::set_details`.
    pub fn set_details(
        &self,
        name: &str,
        category: Option<&str>,
        tags: &[String],
        origin: Option<&str>,
    ) -> Result<BuilderProject, WorkspaceError> {
        let mut p = self
            .project(name)
            .ok_or_else(|| WorkspaceError::new(format!("No project \"{name}\".")))?;
        p.set_details(category, tags, origin);
        self.save_project(&p)?;
        Ok(p)
    }

    /// Resolves a relative path inside a project; refuses anything that leaves it,
    /// any symlink on the way, and `.snazzy*` names (reserved for metadata).
    pub fn resolve(&self, project: &str, path: &str) -> Result<PathBuf, WorkspaceError> {
        let dir = normalize(&self.project_dir(project));
        let cleaned = trim(path);
        if cleaned.is_empty()
            || cleaned.starts_with('/')
            || cleaned.starts_with('~')
            || (cfg!(windows) && (cleaned.contains('\\') || cleaned.contains(':')))
        {
            return Err(WorkspaceError::new(RELATIVE_ONLY));
        }
        let outside = || WorkspaceError::new(format!("Path \"{path}\" is outside the project."));
        // Lexically, like URL.standardizedFileURL: "." dropped, ".." removes a component.
        let full = normalize(&dir.join(cleaned));
        let rel = full
            .strip_prefix(&dir)
            .map_err(|_| outside())?
            .to_path_buf();
        if rel.as_os_str().is_empty() {
            return Err(outside());
        }
        let mut step = dir.clone();
        for part in rel.components() {
            step.push(part);
            if fs::symlink_metadata(&step)
                .map(|m| m.file_type().is_symlink())
                .unwrap_or(false)
            {
                return Err(outside());
            }
        }
        if full
            .file_name()
            .and_then(|n| n.to_str())
            .is_some_and(|n| n.starts_with(".snazzy"))
        {
            return Err(WorkspaceError::new("That file is reserved."));
        }
        Ok(full)
    }

    pub fn write(&self, project: &str, path: &str, content: &str) -> Result<(), WorkspaceError> {
        self.write_bytes(project, path, content.as_bytes())
    }

    pub fn write_bytes(
        &self,
        project: &str,
        path: &str,
        content: &[u8],
    ) -> Result<(), WorkspaceError> {
        if content.len() > MAX_FILE_BYTES {
            return Err(WorkspaceError::new("File too large (max 2 MB)."));
        }
        let url = self.resolve(project, path)?;
        if let Some(parent) = url.parent() {
            fs::create_dir_all(parent).map_err(io)?;
        }
        atomic_write(&url, content)
    }

    pub fn read(&self, project: &str, path: &str) -> Result<String, WorkspaceError> {
        let url = self.resolve(project, path)?;
        let data = fs::read(&url)
            .map_err(|_| WorkspaceError::new(format!("No file \"{path}\" in {project}.")))?;
        if data.len() > MAX_FILE_BYTES {
            return Err(WorkspaceError::new(format!(
                "\"{path}\" is too large to read (over 2 MB)."
            )));
        }
        String::from_utf8(data)
            .map_err(|_| WorkspaceError::new(format!("\"{path}\" is not a text file.")))
    }

    pub fn delete(&self, project: &str, path: &str) -> Result<(), WorkspaceError> {
        let url = self.resolve(project, path)?;
        if !url.exists() {
            return Err(WorkspaceError::new(format!("No file \"{path}\".")));
        }
        fs::remove_file(url).map_err(io)
    }

    /// Relative file paths (with `/`), sorted, without the `.snazzy*` metadata.
    /// Symlinks are skipped.
    pub fn files(&self, project: &str) -> Vec<String> {
        fn walk(dir: &Path, prefix: &str, out: &mut Vec<String>) {
            let Ok(entries) = fs::read_dir(dir) else {
                return;
            };
            for e in entries.flatten() {
                let Ok(kind) = e.file_type() else { continue };
                let name = e.file_name().to_string_lossy().into_owned();
                let rel = if prefix.is_empty() {
                    name
                } else {
                    format!("{prefix}/{name}")
                };
                if kind.is_dir() {
                    walk(&e.path(), &rel, out);
                } else if kind.is_file() {
                    out.push(rel);
                }
            }
        }
        let mut out = Vec::new();
        walk(&self.project_dir(project), "", &mut out);
        out.retain(|p| !p.starts_with(".snazzy"));
        out.sort();
        out
    }

    /// The outline, if the slide editor made the deck.
    pub fn load_outline(&self, project: &str) -> Option<DeckOutline> {
        self.read(project, OUTLINE_FILE)
            .ok()
            .and_then(|t| DeckOutline::from_json(t.as_bytes()))
    }

    /// `DeckOutline.save`: deck.json and (normally) index.html, adding deck.css and
    /// deck.js when they're missing.
    pub fn save_outline(
        &self,
        outline: &DeckOutline,
        project: &str,
        write_html: bool,
    ) -> Result<(), WorkspaceError> {
        self.write(project, OUTLINE_FILE, &outline.to_json())?;
        if write_html {
            self.write(project, "index.html", &outline.html())?;
        }
        let files = self.files(project);
        for (path, content) in template_files(ProjectKind::Presentation, &outline.title) {
            if path != "index.html" && !files.iter().any(|f| f == path) {
                self.write(project, path, &content)?;
            }
        }
        Ok(())
    }
}

impl Workspace {
    /// `Workspace.shareProject`: the project's files for a `.snazzy` file, without
    /// hidden files or Snazzy metadata.
    pub fn share_project(&self, name: &str) -> Result<share::Project, WorkspaceError> {
        let project = self
            .project(name)
            .ok_or_else(|| WorkspaceError::new(format!("No project named {name}")))?;
        let mut files = Vec::new();
        let mut total = 0;
        for path in self.files(&project.name) {
            if !share::is_safe_relative_path(&path) {
                continue;
            }
            let data = fs::read(self.resolve(&project.name, &path)?).map_err(io)?;
            total += data.len();
            if total > share::MAX_EXPANDED_BYTES {
                return Err(WorkspaceError::new("This project is too big to share."));
            }
            files.push(share::File { path, data });
        }
        Ok(share::Project {
            name: project.name,
            kind: project.kind,
            files,
        })
    }

    /// `Workspace.importProject`: a project from someone else, under a free name
    /// ("deck", "deck-2", …), marked shared (no internet until allowed). Nothing is
    /// left behind if a file can't be written.
    pub fn import_project(
        &self,
        shared: &share::Project,
    ) -> Result<BuilderProject, WorkspaceError> {
        let base = slug(&shared.name);
        let existing: Vec<String> = self.list_projects().into_iter().map(|p| p.name).collect();
        let mut name = base.clone();
        let mut n = 2;
        while existing.contains(&name) || self.root.join(&name).exists() {
            name = format!("{base}-{n}");
            n += 1;
        }
        let dir = self.root.join(&name);
        fs::create_dir_all(&dir).map_err(io)?;
        let mut project = BuilderProject::new(name.clone(), shared.kind, Date::now());
        project.set_shared(true);
        let written = self.save_project(&project).and_then(|_| {
            for file in &shared.files {
                if !share::is_safe_relative_path(&file.path) {
                    return Err(WorkspaceError::new(format!(
                        "Unsafe file path: {}",
                        file.path
                    )));
                }
                let url = self.resolve(&name, &file.path)?;
                if let Some(parent) = url.parent() {
                    fs::create_dir_all(parent).map_err(io)?;
                }
                atomic_write(&url, &file.data)?;
            }
            Ok(())
        });
        if let Err(e) = written {
            let _ = fs::remove_dir_all(&dir);
            return Err(e);
        }
        Ok(project)
    }

    /// `Workspace.createSample`: copies a sample into the workspace (or returns the
    /// copy already there), editable in the slide editor, filed under its sector.
    pub fn create_sample(&self, sample: &SampleDeck) -> Result<BuilderProject, WorkspaceError> {
        if let Some(existing) = self.project(&sample.project_name) {
            return Ok(existing);
        }
        let project = self.create_project(
            &sample.project_name,
            ProjectKind::Presentation,
            Some(&sample.title),
        )?;
        for (path, content) in sample.files() {
            self.write(&project.name, path, &content)?;
        }
        let outline = DeckOutline {
            title: sample.title.clone(),
            accent: sample.accent.clone(),
            slides: sample.slides.clone(),
        };
        self.save_outline(&outline, &project.name, false)?;
        self.set_details(
            &project.name,
            Some(&sample.sector),
            &["Sample".to_string()],
            None,
        )
    }

    /// `DeckOutline.create`: a new deck from the slide editor, under a free name.
    pub fn create_deck(&self, outline: &DeckOutline) -> Result<BuilderProject, WorkspaceError> {
        let base = slug(&outline.title);
        let existing: Vec<String> = self.list_projects().into_iter().map(|p| p.name).collect();
        let mut name = base.clone();
        let mut n = 2;
        while existing.contains(&name) {
            name = format!("{base}-{n}");
            n += 1;
        }
        let project =
            self.create_project(&name, ProjectKind::Presentation, Some(&outline.title))?;
        self.save_outline(outline, &project.name, true)?;
        Ok(project)
    }
}

/// Removes "." and resolves ".." without touching the disk.
fn normalize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in path.components() {
        match c {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            other => out.push(other),
        }
    }
    out
}

fn io(e: std::io::Error) -> WorkspaceError {
    WorkspaceError::new(e.to_string())
}

/// Writes to a hidden sibling, then renames over the target.
pub fn atomic_write(path: &Path, data: &[u8]) -> Result<(), WorkspaceError> {
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let tmp = path.with_file_name(format!(".{name}.partial"));
    fs::write(&tmp, data).map_err(io)?;
    fs::rename(&tmp, path).map_err(|e| {
        let _ = fs::remove_file(&tmp);
        io(e)
    })
}
