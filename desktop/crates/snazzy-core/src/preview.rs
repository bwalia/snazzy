//! Serving projects to the app's web views (App/Sources/ProjectSchemeHandler.swift).
//!
//! The Mac serves `snazzy-project://<project>/<path>`, one origin per project.
//! WebView2 serves every custom protocol from one host
//! (`http://snazzy-project.localhost/`), so here a project is reached through a
//! random link made for this run: `/<link>/<path>`. The server answers only links
//! it handed out, so a deck can't guess its way into another project's files.
//!
//! HTML pages get a small bridge script (as the Mac's user scripts): it tells the
//! app which slides the deck has and which is showing, shows a slide when asked,
//! and sends web links to the browser instead of opening them inside the app.

use std::collections::HashMap;
use std::fs;

use crate::workspace::Workspace;

pub const SCHEME: &str = "snazzy-project";

/// Served next to every page; `.snazzy*` names can't be project files.
pub const BRIDGE_FILE: &str = ".snazzy-bridge.js";

/// Reports the deck's slides (heading + speaker notes) on load and the current
/// slide whenever it changes, to the window around it. Works with any deck that
/// exposes `window.snazzyDeck` (the presentation template does). Messages:
/// `{snazzy: "deck", index, slides?}`, `{snazzy: "console", level, message}`,
/// `{snazzy: "open", url}`, `{snazzy: "key", key}` (F and Esc, for full
/// screen); it obeys `{snazzy: "show", index}` and `{snazzy: "refresh"}`.
pub const BRIDGE_JS: &str = r#"(function () {
  if (window.parent === window || window.__snazzyBridge) return;
  window.__snazzyBridge = true;
  let last = null;
  const post = (m) => { try { parent.postMessage(Object.assign({ snazzy: 'deck' }, m), '*'); } catch (e) {} };
  function slides() {
    return Array.from(document.querySelectorAll('.slide')).map(s => {
      const h = s.querySelector('h1, h2, blockquote, h3');
      const n = s.querySelector('.notes');
      return { title: h ? h.textContent.replace(/\s+/g, ' ').trim().slice(0, 160) : '',
               notes: n ? n.textContent.trim().slice(0, 4000) : '',
               isTitle: s.classList.contains('title') };
    });
  }
  function tick(full) {
    const d = window.snazzyDeck;
    if (!d) { if (full) post({ index: -1, slides: [] }); return; }
    const i = d.current();
    if (!full && i === last) return;
    last = i;
    post(full ? { index: i, slides: slides() } : { index: i });
  }
  addEventListener('message', (e) => {
    const m = e.data;
    if (e.source !== parent || !m || typeof m !== 'object') return;
    if (m.snazzy === 'show' && window.snazzyDeck) { window.snazzyDeck.show(m.index); tick(false); }
    if (m.snazzy === 'refresh') tick(true);
  });
  addEventListener('error', (e) => post({ snazzy: 'console', level: 'error', message: String(e.message || e) }));
  // Full screen keys reach the Present window even while the deck has focus.
  addEventListener('keydown', (e) => {
    if (!e.ctrlKey && !e.metaKey && !e.altKey && ['f', 'F', 'Escape'].includes(e.key)) post({ snazzy: 'key', key: e.key });
  });
  addEventListener('click', (e) => {
    const a = e.target && e.target.closest ? e.target.closest('a[href]') : null;
    if (!a) return;
    const url = new URL(a.getAttribute('href'), location.href);
    if (url.protocol === 'http:' || url.protocol === 'https:' || url.protocol === 'mailto:') {
      e.preventDefault();
      post({ snazzy: 'open', url: url.href });
    }
  }, true);
  const start = () => { tick(true); setInterval(() => tick(false), 150); };
  if (document.readyState === 'complete') start(); else addEventListener('load', start);
})();
"#;

/// A response for the web view.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Response {
    pub status: u16,
    pub headers: Vec<(&'static str, String)>,
    pub body: Vec<u8>,
}

impl Response {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(n, _)| n.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }

    fn not_found(path: &str) -> Self {
        Self {
            status: 404,
            headers: vec![("Content-Type", "text/plain; charset=utf-8".into())],
            body: format!("Not found: {path}").into_bytes(),
        }
    }
}

/// The links handed out this run: one per project, made when it's first shown.
#[derive(Debug, Default)]
pub struct Links {
    by_link: HashMap<String, String>,
    by_project: HashMap<String, String>,
}

impl Links {
    pub fn new() -> Self {
        Self::default()
    }

    /// The project's link, made on first use.
    pub fn link(&mut self, project: &str) -> String {
        if let Some(link) = self.by_project.get(project) {
            return link.clone();
        }
        let link = uuid::Uuid::new_v4().simple().to_string();
        self.by_link.insert(link.clone(), project.to_string());
        self.by_project.insert(project.to_string(), link.clone());
        link
    }

    pub fn project(&self, link: &str) -> Option<&str> {
        self.by_link.get(link).map(String::as_str)
    }

    /// After a project is deleted or renamed, its old link stops working.
    pub fn forget(&mut self, project: &str) {
        if let Some(link) = self.by_project.remove(project) {
            self.by_link.remove(&link);
        }
    }
}

/// `/<link>/<path>` from a request path: the link and the file inside the
/// project (percent-decoded; `index.html` for a folder).
pub fn split_path(path: &str) -> Option<(&str, String)> {
    let path = path.split(['?', '#']).next().unwrap_or("");
    let rest = path.strip_prefix('/').unwrap_or(path);
    let (link, file) = rest.split_once('/').unwrap_or((rest, ""));
    if link.is_empty() {
        return None;
    }
    let mut file = percent_decode(file)?;
    if file.is_empty() || file.ends_with('/') {
        file.push_str("index.html");
    }
    Some((link, file))
}

/// `%XX` escapes to UTF-8 text; None for broken escapes or text.
pub fn percent_decode(s: &str) -> Option<String> {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = s.get(i + 1..i + 3)?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// The MIME type for a file name (the web types decks use).
pub fn mime_type(path: &str) -> &'static str {
    let ext = path
        .rsplit('/')
        .next()
        .and_then(|n| n.rsplit_once('.'))
        .map(|(_, e)| e.to_ascii_lowercase())
        .unwrap_or_default();
    match ext.as_str() {
        "html" | "htm" => "text/html",
        "css" => "text/css",
        "js" | "mjs" => "text/javascript",
        "json" => "application/json",
        "txt" | "md" => "text/plain",
        "vtt" => "text/vtt",
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "avif" => "image/avif",
        "ico" => "image/x-icon",
        "woff" => "font/woff",
        "woff2" => "font/woff2",
        "ttf" => "font/ttf",
        "otf" => "font/otf",
        "mp4" | "m4v" => "video/mp4",
        "webm" => "video/webm",
        "mp3" => "audio/mpeg",
        "m4a" => "audio/mp4",
        "wav" => "audio/wav",
        "wasm" => "application/wasm",
        _ => "application/octet-stream",
    }
}

/// `Content-Type`, with `charset=utf-8` for text (as the Mac).
pub fn content_type(path: &str) -> String {
    let mime = mime_type(path);
    let textual = mime.starts_with("text/")
        || mime.contains("javascript")
        || mime.contains("json")
        || mime.contains("svg");
    if textual {
        format!("{mime}; charset=utf-8")
    } else {
        mime.to_string()
    }
}

/// A project from someone else may only load its own files: no requests to the
/// internet (a page can tighten this policy, never loosen it).
pub const SHARED_CSP: &str = "default-src 'self' 'unsafe-inline' 'unsafe-eval' data: blob:";

/// Adds the bridge script to an HTML page, at the end of its body.
pub fn inject_bridge(html: &str, src: &str) -> String {
    let tag = format!("<script src=\"{src}\"></script>");
    match html.to_ascii_lowercase().rfind("</body>") {
        Some(at) => format!("{}{tag}{}", &html[..at], &html[at..]),
        None => format!("{html}{tag}"),
    }
}

/// Answers a request for `/<link>/<path>`.
pub fn serve(workspace: &Workspace, links: &Links, path: &str) -> Response {
    let Some((link, file)) = split_path(path) else {
        return Response::not_found(path);
    };
    let Some(project) = links.project(link) else {
        return Response::not_found(&file);
    };
    let shared = workspace.project(project).is_some_and(|p| p.is_shared());
    let body = if file == BRIDGE_FILE {
        BRIDGE_JS.as_bytes().to_vec()
    } else {
        match workspace
            .resolve(project, &file)
            .ok()
            .and_then(|f| fs::read(f).ok())
        {
            Some(data) => data,
            None => return Response::not_found(&file),
        }
    };
    let body = if mime_type(&file) == "text/html" {
        match String::from_utf8(body) {
            Ok(html) => inject_bridge(&html, &format!("/{link}/{BRIDGE_FILE}")).into_bytes(),
            Err(e) => e.into_bytes(),
        }
    } else {
        body
    };
    let mut headers = vec![
        ("Content-Type", content_type(&file)),
        ("Cache-Control", "no-store".to_string()),
    ];
    if shared {
        headers.push(("Content-Security-Policy", SHARED_CSP.to_string()));
    }
    Response {
        status: 200,
        headers,
        body,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::ProjectKind;

    #[test]
    fn paths_split_into_link_and_file() {
        assert_eq!(split_path("/abc/"), Some(("abc", "index.html".into())));
        assert_eq!(split_path("/abc"), Some(("abc", "index.html".into())));
        assert_eq!(
            split_path("/abc/img/a%20b.png?x=1#y"),
            Some(("abc", "img/a b.png".into()))
        );
        assert_eq!(
            split_path("/abc/css/"),
            Some(("abc", "css/index.html".into()))
        );
        assert_eq!(split_path("/"), None);
        assert_eq!(split_path("/abc/%zz"), None);
        assert_eq!(percent_decode("caf%C3%A9"), Some("café".into()));
    }

    #[test]
    fn types_and_bridge() {
        assert_eq!(content_type("index.html"), "text/html; charset=utf-8");
        assert_eq!(content_type("a/deck.js"), "text/javascript; charset=utf-8");
        assert_eq!(content_type("logo.SVG"), "image/svg+xml; charset=utf-8");
        assert_eq!(content_type("photo.jpeg"), "image/jpeg");
        assert_eq!(content_type("noext"), "application/octet-stream");
        assert_eq!(
            inject_bridge("<html><body>x</BODY></html>", "/l/b.js"),
            "<html><body>x<script src=\"/l/b.js\"></script></BODY></html>"
        );
        assert_eq!(
            inject_bridge("<p>x", "b.js"),
            "<p>x<script src=\"b.js\"></script>"
        );
    }

    #[test]
    fn serves_only_links_it_made() {
        let dir = tempfile::tempdir().unwrap();
        let ws = Workspace::new(dir.path());
        ws.create_project("Mine", ProjectKind::Presentation, None)
            .unwrap();
        ws.create_project("Theirs", ProjectKind::Presentation, None)
            .unwrap();
        ws.set_shared("theirs", true).unwrap();
        let mut links = Links::new();
        let mine = links.link("mine");
        assert_eq!(links.link("mine"), mine, "one link per project");
        let theirs = links.link("theirs");
        assert_ne!(mine, theirs);
        assert_eq!(mine.len(), 32);

        let page = serve(&ws, &links, &format!("/{mine}/"));
        assert_eq!(page.status, 200);
        assert_eq!(page.header("Cache-Control"), Some("no-store"));
        assert_eq!(page.header("Content-Security-Policy"), None);
        let html = String::from_utf8(page.body).unwrap();
        assert!(html.contains("class=\"slide"));
        assert!(html.contains(&format!("<script src=\"/{mine}/{BRIDGE_FILE}\"></script>")));

        let bridge = serve(&ws, &links, &format!("/{mine}/{BRIDGE_FILE}"));
        assert_eq!(bridge.body, BRIDGE_JS.as_bytes());

        let shared = serve(&ws, &links, &format!("/{theirs}/deck.css"));
        assert_eq!(shared.status, 200);
        assert_eq!(shared.header("Content-Security-Policy"), Some(SHARED_CSP));

        // Unknown links, project names, escapes and metadata are not served.
        for path in [
            "/mine/index.html".to_string(),
            format!("/{}/index.html", "0".repeat(32)),
            format!("/{mine}/../theirs/index.html"),
            format!("/{mine}/%2E%2E/theirs/index.html"),
            format!("/{mine}/.snazzy-project.json"),
            format!("/{mine}/missing.png"),
        ] {
            assert_eq!(serve(&ws, &links, &path).status, 404, "{path}");
        }
        links.forget("mine");
        assert_eq!(serve(&ws, &links, &format!("/{mine}/")).status, 404);
    }
}
