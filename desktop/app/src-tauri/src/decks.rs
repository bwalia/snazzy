//! Decks: the library (My Decks, samples, search), the Builder preview served
//! over `snazzy-project:`, the slide editor, the Present window, GitHub deck repos
//! and `.snazzy` files. The work is in `snazzy_core`; these are the commands the
//! window calls (and, from phase 4, the assistant's tools).

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Duration;

use serde::Serialize;
use snazzy_core::deck::DeckOutline;
use snazzy_core::deck_repo::{self, DeckRepo, RemoteDeck};
use snazzy_core::iso8601::Date;
use snazzy_core::preview::{self, Links};
use snazzy_core::project::ProjectKind;
use snazzy_core::share::{self, Share};
use snazzy_core::workspace::{Workspace, atomic_write};
use snazzy_core::{samples, search};
use tauri::{AppHandle, Emitter, Manager, State, WebviewUrl, WebviewWindowBuilder};

/// Where the web views reach `snazzy-project:` (WebView2 only serves custom
/// protocols from an http host).
#[cfg(windows)]
const PREVIEW_BASE: &str = "http://snazzy-project.localhost";
#[cfg(not(windows))]
const PREVIEW_BASE: &str = "snazzy-project://localhost";

const PRESENT_WINDOW: &str = "present";
const NO_HOME: &str = "Can't find your home folder, so there's nowhere to keep decks.";

pub struct DeckState {
    workspace: Option<Workspace>,
    downloads: Option<PathBuf>,
    repos_file: Option<PathBuf>,
    links: Mutex<Links>,
    presenting: Mutex<Option<Presenting>>,
    repos: Mutex<Vec<DeckRepo>>,
    /// Decks listed per repo (by repo id), as GitHub last answered.
    listed: Mutex<HashMap<String, Vec<RemoteDeck>>>,
    adding: Mutex<HashSet<String>>,
    /// A `.snazzy` file the app was opened with, until the window asks for it.
    opened_file: Mutex<Option<PathBuf>>,
    http: reqwest::Client,
}

impl DeckState {
    pub fn new(opened_file: Option<PathBuf>) -> Self {
        let folders = snazzy_platform::paths::folders();
        let repos_file = folders.as_ref().map(|f| f.data.join("deck-repos.json"));
        let saved: Vec<DeckRepo> = repos_file
            .as_ref()
            .and_then(|p| std::fs::read(p).ok())
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        let official = DeckRepo::official();
        let mut repos = vec![official.clone()];
        repos.extend(saved.into_iter().filter(|r| *r != official));
        Self {
            workspace: folders.as_ref().map(|f| Workspace::new(&f.projects)),
            downloads: folders.map(|f| f.downloads),
            repos_file,
            links: Mutex::new(Links::new()),
            presenting: Mutex::new(None),
            repos: Mutex::new(repos),
            listed: Mutex::new(HashMap::new()),
            adding: Mutex::new(HashSet::new()),
            opened_file: Mutex::new(opened_file),
            http: reqwest::Client::builder()
                .user_agent("SnazzyPro")
                .timeout(Duration::from_secs(30))
                .build()
                .unwrap_or_default(),
        }
    }

    fn ws(&self) -> Result<&Workspace, String> {
        self.workspace.as_ref().ok_or_else(|| NO_HOME.to_string())
    }

    /// Answers the web views' `snazzy-project:` requests.
    pub fn serve(&self, path: &str) -> preview::Response {
        match &self.workspace {
            Some(ws) => preview::serve(ws, &lock(&self.links), path),
            None => preview::serve(&Workspace::new(""), &Links::new(), path),
        }
    }

    fn url(&self, project: &str) -> String {
        let link = lock(&self.links).link(project);
        format!("{PREVIEW_BASE}/{link}/index.html")
    }

    fn open(&self, name: &str) -> Result<OpenDeck, String> {
        let ws = self.ws()?;
        let p = ws
            .project(name)
            .ok_or_else(|| format!("No project named {name}"))?;
        let title = search::deck(&p.name, ws)
            .map(|d| d.title)
            .filter(|t| !t.is_empty())
            .unwrap_or_else(|| p.name.clone());
        Ok(OpenDeck {
            url: self.url(&p.name),
            title,
            kind: p.kind,
            shared: p.is_shared(),
            has_outline: ws.load_outline(&p.name).is_some(),
            files: ws.files(&p.name),
            category: p.category.clone(),
            tags: p.tags.clone().unwrap_or_default(),
            origin: p.origin.clone(),
            name: p.name,
        })
    }

    fn save_repos(&self, repos: &[DeckRepo]) {
        let Some(path) = &self.repos_file else { return };
        let custom: Vec<&DeckRepo> = repos
            .iter()
            .filter(|r| **r != DeckRepo::official())
            .collect();
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Ok(json) = serde_json::to_vec_pretty(&custom) {
            let _ = atomic_write(path, &json);
        }
    }

    fn repo(&self, id: &str) -> Result<DeckRepo, String> {
        lock(&self.repos)
            .iter()
            .find(|r| r.id() == id)
            .cloned()
            .ok_or_else(|| "That deck repo isn't in the list any more.".to_string())
    }

    fn import(&self, data: &[u8]) -> Result<Imported, String> {
        let share = Share::decode(data).map_err(|e| e.to_string())?;
        let mut skipped = Vec::new();
        if !share.presets.is_empty() {
            skipped.push(count(share.presets.len(), "preset"));
        }
        if !share.backgrounds.is_empty() {
            skipped.push(count(share.backgrounds.len(), "background"));
        }
        let Some(project) = &share.project else {
            return Err(format!(
                "“{}” has no deck in it, only {}. Presets and backgrounds arrive with Sources & Preview.",
                share.title,
                skipped.join(" and ")
            ));
        };
        let p = self
            .ws()?
            .import_project(project)
            .map_err(|e| e.to_string())?;
        Ok(Imported {
            deck: self.open(&p.name)?,
            note: share.note,
            skipped,
        })
    }
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

fn count(n: usize, what: &str) -> String {
    format!("{n} {what}{}", if n == 1 { "" } else { "s" })
}

fn err(e: impl ToString) -> String {
    e.to_string()
}

// MARK: Library

/// A project, opened in the Builder.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenDeck {
    name: String,
    title: String,
    kind: ProjectKind,
    /// Where the web view loads it.
    url: String,
    /// From someone else: no internet until allowed.
    shared: bool,
    /// Made in the slide editor (or a sample): editable without AI.
    has_outline: bool,
    files: Vec<String>,
    category: Option<String>,
    tags: Vec<String>,
    origin: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LibraryDeck {
    name: String,
    title: String,
    kind: ProjectKind,
    category: String,
    tags: Vec<String>,
    slides: usize,
    created: Option<i64>,
    shared: bool,
    origin: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LibrarySample {
    id: String,
    sector: String,
    title: String,
    use_case: String,
    audience: String,
    minutes: u32,
    slides: usize,
    setup: Vec<String>,
    prompt: String,
    accent: String,
    /// The project it was opened as, if it has been.
    opened: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Library {
    decks: Vec<LibraryDeck>,
    samples: Vec<LibrarySample>,
    sectors: Vec<String>,
}

#[tauri::command]
pub fn deck_library(state: State<'_, DeckState>) -> Result<Library, String> {
    let ws = state.ws()?;
    let projects = ws.list_projects();
    let decks = projects
        .iter()
        .map(|p| {
            let d = search::deck(&p.name, ws);
            LibraryDeck {
                name: p.name.clone(),
                title: d
                    .as_ref()
                    .map(|d| d.title.clone())
                    .filter(|t| !t.is_empty())
                    .unwrap_or_else(|| p.name.clone()),
                kind: p.kind,
                category: d.as_ref().map_or_else(
                    || search::Deck::UNCATEGORISED.to_string(),
                    |d| d.category_name().to_string(),
                ),
                tags: p.tags.clone().unwrap_or_default(),
                slides: d.as_ref().map_or(0, |d| d.slides.len()),
                created: d.and_then(|d| d.created),
                shared: p.is_shared(),
                origin: p.origin.clone(),
            }
        })
        .collect();
    let samples = samples::all()
        .iter()
        .map(|s| LibrarySample {
            id: s.id.clone(),
            sector: s.sector.clone(),
            title: s.title.clone(),
            use_case: s.use_case.clone(),
            audience: s.audience.clone(),
            minutes: s.minutes,
            slides: s.slides.len(),
            setup: s.setup.clone(),
            prompt: s.prompt.clone(),
            accent: s.accent.clone(),
            opened: projects
                .iter()
                .find(|p| p.name == s.project_name)
                .map(|p| p.name.clone()),
        })
        .collect();
    Ok(Library {
        decks,
        samples,
        sectors: samples::sectors().into_iter().map(String::from).collect(),
    })
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SlideHit {
    /// The project to open, or the sample to open first.
    project: Option<String>,
    sample: Option<String>,
    deck_title: String,
    slide: usize,
    heading: String,
    field: &'static str,
    snippet: String,
}

/// Every slide's title, text and speaker notes, including unopened samples.
#[tauri::command]
pub fn search_slides(state: State<'_, DeckState>, query: String) -> Result<Vec<SlideHit>, String> {
    let decks = search::decks(state.ws()?, samples::all());
    Ok(search::search(&query, &decks, 60)
        .into_iter()
        .map(|h| {
            let (project, sample) = match h.deck {
                search::Source::Project(p) => (Some(p), None),
                search::Source::Sample(s) => (None, Some(s)),
            };
            SlideHit {
                project,
                sample,
                deck_title: h.deck_title,
                slide: h.slide,
                heading: h.heading,
                field: h.field.raw(),
                snippet: h.snippet,
            }
        })
        .collect())
}

#[tauri::command]
pub fn open_deck(state: State<'_, DeckState>, name: String) -> Result<OpenDeck, String> {
    state.open(&name)
}

/// Copies a sample into My Decks (or finds the copy) and opens it.
#[tauri::command]
pub fn open_sample(state: State<'_, DeckState>, id: String) -> Result<OpenDeck, String> {
    let sample = samples::get(&id).ok_or_else(|| format!("No sample deck {id}"))?;
    let p = state.ws()?.create_sample(sample).map_err(err)?;
    state.open(&p.name)
}

/// A new deck from the slide editor's starter: title, a bullet slide, thanks.
#[tauri::command]
pub fn new_deck(state: State<'_, DeckState>, title: String) -> Result<OpenDeck, String> {
    let title = title.trim();
    let title = if title.is_empty() {
        "Untitled deck"
    } else {
        title
    };
    let p = state
        .ws()?
        .create_deck(&DeckOutline::starter(title))
        .map_err(err)?;
    state.open(&p.name)
}

#[tauri::command]
pub fn deck_outline(
    state: State<'_, DeckState>,
    name: String,
) -> Result<Option<DeckOutline>, String> {
    Ok(state.ws()?.load_outline(&name))
}

/// Saves the slide editor's changes: deck.json and index.html.
#[tauri::command]
pub fn save_deck_outline(
    state: State<'_, DeckState>,
    name: String,
    outline: DeckOutline,
) -> Result<OpenDeck, String> {
    if outline.slides.is_empty() {
        return Err("A deck needs at least one slide.".into());
    }
    let ws = state.ws()?;
    if ws.project(&name).is_none() {
        return Err(format!("No project named {name}"));
    }
    ws.save_outline(&outline, &name, true).map_err(err)?;
    state.open(&name)
}

#[tauri::command]
pub fn set_deck_details(
    state: State<'_, DeckState>,
    name: String,
    category: Option<String>,
    tags: Vec<String>,
) -> Result<OpenDeck, String> {
    state
        .ws()?
        .set_details(&name, category.as_deref(), &tags, None)
        .map_err(err)?;
    state.open(&name)
}

/// Lets a deck from someone else reach the internet (fonts, libraries, data).
#[tauri::command]
pub fn allow_deck_internet(state: State<'_, DeckState>, name: String) -> Result<OpenDeck, String> {
    state.ws()?.set_shared(&name, false).map_err(err)?;
    state.open(&name)
}

/// Deletes a project folder. The window asks first.
#[tauri::command]
pub fn delete_deck(
    app: AppHandle,
    state: State<'_, DeckState>,
    name: String,
) -> Result<(), String> {
    state.ws()?.delete_project(&name).map_err(err)?;
    lock(&state.links).forget(&name);
    let presenting = lock(&state.presenting)
        .as_ref()
        .is_some_and(|p| p.name == name);
    if presenting {
        close_present(&app, &state);
    }
    Ok(())
}

// MARK: .snazzy files

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Imported {
    deck: OpenDeck,
    /// The sender's note, if any.
    note: String,
    /// What the file also had that this version can't add yet.
    skipped: Vec<String>,
}

/// Imports a `.snazzy` file's deck (the bytes are the request body).
#[tauri::command]
pub fn import_share(
    state: State<'_, DeckState>,
    request: tauri::ipc::Request<'_>,
) -> Result<Imported, String> {
    match request.body() {
        tauri::ipc::InvokeBody::Raw(bytes) => state.import(bytes),
        _ => Err("No file was sent.".into()),
    }
}

/// The `.snazzy` file the app was opened with (double-clicked), if not yet
/// imported or declined.
#[tauri::command]
pub fn opened_file(state: State<'_, DeckState>) -> Option<String> {
    lock(&state.opened_file)
        .as_ref()
        .map(|p| p.to_string_lossy().into_owned())
}

/// Imports the file the app was opened with, after the window asked (or drops
/// it when the answer was no).
#[tauri::command]
pub fn import_opened_file(
    state: State<'_, DeckState>,
    accept: bool,
) -> Result<Option<Imported>, String> {
    let Some(path) = lock(&state.opened_file).take() else {
        return Ok(None);
    };
    if !accept {
        return Ok(None);
    }
    let data = std::fs::read(&path).map_err(|e| format!("Couldn't read the file: {e}"))?;
    state.import(&data).map(Some)
}

/// Saves a deck as a `.snazzy` file in Downloads. Returns where.
#[tauri::command]
pub fn export_deck(state: State<'_, DeckState>, name: String) -> Result<String, String> {
    let ws = state.ws()?;
    let project = ws.share_project(&name).map_err(err)?;
    let title = search::deck(&project.name, ws).map_or_else(|| project.name.clone(), |d| d.title);
    let data = Share::new(&title, "", Some(project), vec![], vec![], Date::now())
        .encode()
        .map_err(err)?;
    let dir = state.downloads.clone().ok_or_else(|| NO_HOME.to_string())?;
    std::fs::create_dir_all(&dir).map_err(err)?;
    let path = free_file(&dir, &name, share::FILE_EXTENSION);
    atomic_write(&path, &data).map_err(err)?;
    Ok(path.to_string_lossy().into_owned())
}

/// `name.ext`, or `name-2.ext`, … if that's taken.
fn free_file(dir: &Path, name: &str, ext: &str) -> PathBuf {
    let mut path = dir.join(format!("{name}.{ext}"));
    let mut n = 2;
    while path.exists() {
        path = dir.join(format!("{name}-{n}.{ext}"));
        n += 1;
    }
    path
}

#[tauri::command]
pub fn show_downloads(state: State<'_, DeckState>) -> Result<(), String> {
    let dir = state.downloads.clone().ok_or_else(|| NO_HOME.to_string())?;
    snazzy_platform::open::open_folder(&dir)
}

/// Opens a deck's web link in the browser (decks never navigate away inside the app).
#[tauri::command]
pub fn open_link(url: String) -> Result<(), String> {
    snazzy_platform::open::open_url(&url)
}

// MARK: Present window

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Presenting {
    name: String,
    title: String,
    url: String,
    index: usize,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Display {
    index: usize,
    name: String,
    width: u32,
    height: u32,
    primary: bool,
}

#[tauri::command]
pub fn displays(app: AppHandle) -> Vec<Display> {
    let primary = app.primary_monitor().ok().flatten();
    app.available_monitors()
        .unwrap_or_default()
        .into_iter()
        .enumerate()
        .map(|(index, m)| Display {
            index,
            name: m
                .name()
                .cloned()
                .unwrap_or_else(|| format!("Display {}", index + 1)),
            width: m.size().width,
            height: m.size().height,
            primary: primary
                .as_ref()
                .is_some_and(|p| p.position() == m.position() && p.size() == m.size()),
        })
        .collect()
}

/// Opens (or moves) the Present window: the deck alone, full screen on the
/// chosen display, or in a 16:9 window when none is chosen.
#[tauri::command]
pub fn present_open(
    app: AppHandle,
    state: State<'_, DeckState>,
    name: String,
    index: usize,
    display: Option<usize>,
) -> Result<Presenting, String> {
    let deck = state.open(&name)?;
    let presenting = Presenting {
        name: deck.name,
        title: deck.title,
        url: deck.url,
        index,
    };
    *lock(&state.presenting) = Some(presenting.clone());
    let monitor = display.and_then(|i| app.available_monitors().ok()?.into_iter().nth(i));
    let window = match app.get_webview_window(PRESENT_WINDOW) {
        Some(w) => w,
        None => {
            let w = WebviewWindowBuilder::new(
                &app,
                PRESENT_WINDOW,
                WebviewUrl::App("index.html?view=present".into()),
            )
            .title(format!("{} · Snazzy Pro", presenting.title))
            .inner_size(1280.0, 720.0)
            .min_inner_size(480.0, 270.0)
            .build()
            .map_err(err)?;
            let handle = app.clone();
            w.on_window_event(move |e| {
                if let tauri::WindowEvent::Destroyed = e {
                    *lock(&handle.state::<DeckState>().presenting) = None;
                    let _ = handle.emit("present", None::<Presenting>);
                }
            });
            w
        }
    };
    let _ = window.set_title(&format!("{} · Snazzy Pro", presenting.title));
    if let Some(m) = monitor {
        let _ = window.set_fullscreen(false);
        let _ = window.set_position(*m.position());
        let _ = window.set_fullscreen(true);
    }
    let _ = window.set_focus();
    let _ = app.emit("present", Some(presenting.clone()));
    Ok(presenting)
}

/// What's showing in the Present window, if it's open.
#[tauri::command]
pub fn present_state(state: State<'_, DeckState>) -> Option<Presenting> {
    lock(&state.presenting).clone()
}

/// Shows a slide in every window presenting the deck.
#[tauri::command]
pub fn present_go(app: AppHandle, state: State<'_, DeckState>, index: usize) -> Option<Presenting> {
    let mut presenting = lock(&state.presenting);
    let p = presenting.as_mut()?;
    if p.index != index {
        p.index = index;
        let _ = app.emit("present", Some(p.clone()));
    }
    Some(p.clone())
}

#[tauri::command]
pub fn present_fullscreen(app: AppHandle, on: Option<bool>) -> Result<bool, String> {
    let w = app
        .get_webview_window(PRESENT_WINDOW)
        .ok_or("The Present window isn't open.")?;
    let on = on.unwrap_or(!w.is_fullscreen().unwrap_or(false));
    w.set_fullscreen(on).map_err(err)?;
    Ok(on)
}

#[tauri::command]
pub fn present_close(app: AppHandle, state: State<'_, DeckState>) {
    close_present(&app, &state);
}

fn close_present(app: &AppHandle, state: &DeckState) {
    *lock(&state.presenting) = None;
    if let Some(w) = app.get_webview_window(PRESENT_WINDOW) {
        let _ = w.destroy();
    }
    let _ = app.emit("present", None::<Presenting>);
}

// MARK: Get Decks (GitHub)

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RepoInfo {
    id: String,
    name: String,
    url: String,
    official: bool,
}

impl From<&DeckRepo> for RepoInfo {
    fn from(r: &DeckRepo) -> Self {
        Self {
            id: r.id(),
            name: r.name(),
            url: r.web_url(),
            official: *r == DeckRepo::official(),
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RepoDeckInfo {
    id: String,
    title: String,
    description: String,
    category: Option<String>,
    tags: Vec<String>,
    author: Option<String>,
    files: usize,
    bytes: u64,
    url: String,
    /// The project it was added as, if it has been.
    added: Option<String>,
}

#[tauri::command]
pub fn deck_repos(state: State<'_, DeckState>) -> Vec<RepoInfo> {
    lock(&state.repos).iter().map(RepoInfo::from).collect()
}

/// Adds a repo from what was typed ("owner/repo" or a GitHub link).
#[tauri::command]
pub fn add_deck_repo(state: State<'_, DeckState>, text: String) -> Result<RepoInfo, String> {
    let repo = DeckRepo::parse(&text).ok_or(
        "That doesn't look like a GitHub repo. Use owner/repo, or paste a github.com link.",
    )?;
    let mut repos = lock(&state.repos);
    if !repos.contains(&repo) {
        repos.push(repo.clone());
        state.save_repos(&repos);
    }
    Ok(RepoInfo::from(&repo))
}

#[tauri::command]
pub fn remove_deck_repo(state: State<'_, DeckState>, id: String) {
    let mut repos = lock(&state.repos);
    repos.retain(|r| r.id() != id || *r == DeckRepo::official());
    state.save_repos(&repos);
    lock(&state.listed).remove(&id);
}

/// The decks in a repo, from GitHub (or as listed earlier unless `force`).
#[tauri::command]
pub async fn list_repo_decks(
    state: State<'_, DeckState>,
    id: String,
    force: bool,
) -> Result<Vec<RepoDeckInfo>, String> {
    let repo = state.repo(&id)?;
    let cached = (!force)
        .then(|| lock(&state.listed).get(&id).cloned())
        .flatten();
    let decks = match cached {
        Some(d) => d,
        None => {
            let decks = load_repo(&state.http, &repo).await?;
            lock(&state.listed).insert(id, decks.clone());
            decks
        }
    };
    let projects = state.ws()?.list_projects();
    Ok(decks
        .iter()
        .map(|d| RepoDeckInfo {
            id: d.id(),
            title: d.title.clone(),
            description: d.description.clone(),
            category: d.category.clone(),
            tags: d.tags.clone(),
            author: d.author.clone(),
            files: d.files.len(),
            bytes: d.bytes,
            url: d.web_url(),
            added: projects
                .iter()
                .find(|p| p.origin.as_deref() == Some(&d.origin()))
                .map(|p| p.name.clone()),
        })
        .collect())
}

async fn load_repo(http: &reqwest::Client, repo: &DeckRepo) -> Result<Vec<RemoteDeck>, String> {
    let branch = match &repo.branch {
        Some(b) => b.clone(),
        None => {
            let data = get(http, &repo.repo_api()).await?;
            serde_json::from_slice::<serde_json::Value>(&data)
                .ok()
                .and_then(|v| v["default_branch"].as_str().map(String::from))
                .unwrap_or_else(|| "main".into())
        }
    };
    let tree = get(http, &repo.tree_api(&branch)).await?;
    let (entries, truncated) = deck_repo::parse_tree(&tree)
        .map_err(|_| "GitHub's answer didn't make sense. Try again later.".to_string())?;
    let catalogue_path = if repo.path.is_empty() {
        deck_repo::CATALOGUE_FILE.to_string()
    } else {
        format!("{}/{}", repo.path, deck_repo::CATALOGUE_FILE)
    };
    let catalogue = if entries.iter().any(|e| e.path == catalogue_path) {
        get(http, &repo.raw_url(&branch, &catalogue_path))
            .await
            .ok()
            .and_then(|d| deck_repo::parse_catalogue(&d))
    } else {
        None
    };
    let decks = deck_repo::decks(repo, &branch, &entries, catalogue.as_ref());
    if decks.is_empty() {
        let hint = if truncated {
            " The repo is very large; point to its decks folder, like owner/repo/decks."
        } else {
            ""
        };
        return Err(format!(
            "No decks found in {}. A deck is a folder with an index.html.{hint}",
            repo.name()
        ));
    }
    Ok(decks)
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct Progress {
    id: String,
    done: usize,
    total: usize,
}

/// Downloads a deck, adds it to My Decks with its category and tags (no internet
/// until allowed, like any deck from someone else) and opens it.
#[tauri::command]
pub async fn add_repo_deck(
    app: AppHandle,
    state: State<'_, DeckState>,
    repo_id: String,
    deck_id: String,
) -> Result<OpenDeck, String> {
    let deck = lock(&state.listed)
        .get(&repo_id)
        .and_then(|decks| decks.iter().find(|d| d.id() == deck_id).cloned())
        .ok_or("List the repo's decks first.")?;
    let ws = state.ws()?;
    if let Some(p) = ws
        .list_projects()
        .into_iter()
        .find(|p| p.origin.as_deref() == Some(&deck.origin()))
    {
        return state.open(&p.name);
    }
    if !lock(&state.adding).insert(deck.id()) {
        return Err(format!("“{}” is already being added.", deck.title));
    }
    let result = download(&app, &state.http, &deck).await;
    lock(&state.adding).remove(&deck.id());
    let imported = ws
        .import_project(&deck_repo::project_for(&deck, result?))
        .map_err(err)?;
    let mut tags = deck.tags.clone();
    if deck.repo != DeckRepo::official() {
        tags.push(deck.repo.owner.clone());
    }
    let p = ws
        .set_details(
            &imported.name,
            deck.category.as_deref(),
            &tags,
            Some(&deck.origin()),
        )
        .map_err(err)?;
    state.open(&p.name)
}

async fn download(
    app: &AppHandle,
    http: &reqwest::Client,
    deck: &RemoteDeck,
) -> Result<Vec<(String, Vec<u8>)>, String> {
    let mut files = Vec::new();
    let mut total = 0u64;
    let too_big = || format!("“{}” is too big to add.", deck.title);
    for path in &deck.files {
        let full = if deck.folder.is_empty() {
            path.clone()
        } else {
            format!("{}/{path}", deck.folder)
        };
        let data = get(http, &deck.repo.raw_url(&deck.branch, &full)).await?;
        total += data.len() as u64;
        if data.len() as u64 > deck_repo::MAX_FILE_BYTES || total > deck_repo::MAX_DECK_BYTES {
            return Err(too_big());
        }
        files.push((path.clone(), data));
        let _ = app.emit(
            "deck-adding",
            Progress {
                id: deck.id(),
                done: files.len(),
                total: deck.files.len(),
            },
        );
    }
    Ok(files)
}

/// A GET to GitHub, with the Mac's messages for what goes wrong.
async fn get(http: &reqwest::Client, url: &str) -> Result<Vec<u8>, String> {
    let mut request = http.get(url);
    if url.starts_with("https://api.github.com/") {
        request = request
            .header("Accept", "application/vnd.github+json")
            .header("X-GitHub-Api-Version", "2022-11-28");
    }
    let response = request
        .send()
        .await
        .map_err(|_| "No answer from GitHub. Check your internet connection.".to_string())?;
    match response.status().as_u16() {
        200..=299 => response
            .bytes()
            .await
            .map(|b| b.to_vec())
            .map_err(|_| "The download from GitHub was cut off.".to_string()),
        404 => Err("Not found on GitHub. Check the name, and that the repo is public.".into()),
        403 | 429 => Err(
            "GitHub's limit for browsing without an account was reached. Try again in an hour."
                .into(),
        ),
        code => Err(format!("GitHub answered {code}.")),
    }
}

/// A `.snazzy` file among the app's arguments (double-clicked in the file manager).
pub fn file_to_open(args: impl IntoIterator<Item = String>) -> Option<PathBuf> {
    args.into_iter().skip(1).map(PathBuf::from).find(|p| {
        p.extension()
            .is_some_and(|e| e.eq_ignore_ascii_case(share::FILE_EXTENSION))
            && p.is_file()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exports_never_overwrite() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(
            free_file(dir.path(), "q3", "snazzy"),
            dir.path().join("q3.snazzy")
        );
        std::fs::write(dir.path().join("q3.snazzy"), b"x").unwrap();
        std::fs::write(dir.path().join("q3-2.snazzy"), b"x").unwrap();
        assert_eq!(
            free_file(dir.path(), "q3", "snazzy"),
            dir.path().join("q3-3.snazzy")
        );
    }

    #[test]
    fn finds_the_share_file_it_was_opened_with() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("Deck.SNAZZY");
        std::fs::write(&file, b"x").unwrap();
        let s = |p: &Path| p.to_string_lossy().into_owned();
        let args = vec![
            "app".into(),
            "--flag".into(),
            s(&dir.path().join("missing.snazzy")),
            s(&file),
        ];
        assert_eq!(file_to_open(args), Some(file.clone()));
        assert_eq!(
            file_to_open(vec![s(&file)]),
            None,
            "the program itself isn't a file to open"
        );
    }
}
