//! Opening links in the browser and folders in the file manager, with the
//! system's own handler (`rundll32 url.dll` on Windows, `xdg-open` on Linux).

use std::path::Path;
use std::process::Command;

/// Only web and mail links leave the app this way.
pub fn is_openable(url: &str) -> bool {
    let lower = url.to_ascii_lowercase();
    (lower.starts_with("https://") || lower.starts_with("http://") || lower.starts_with("mailto:"))
        && !url.chars().any(char::is_control)
}

/// Opens a web or mail link in the default app.
pub fn open_url(url: &str) -> Result<(), String> {
    if !is_openable(url) {
        return Err("Only web and email links can be opened.".into());
    }
    launch(url)
}

/// Shows a folder in the file manager.
pub fn open_folder(path: &Path) -> Result<(), String> {
    if !path.is_dir() {
        return Err(format!("No folder at {}", path.display()));
    }
    launch(&path.to_string_lossy())
}

fn launch(target: &str) -> Result<(), String> {
    #[cfg(windows)]
    let mut command = {
        let mut c = Command::new("rundll32.exe");
        c.arg("url.dll,FileProtocolHandler");
        c
    };
    #[cfg(target_os = "macos")]
    let mut command = Command::new("open");
    #[cfg(not(any(windows, target_os = "macos")))]
    let mut command = Command::new("xdg-open");
    command
        .arg(target)
        .spawn()
        .map(drop)
        .map_err(|e| format!("Couldn't open it: {e}"))
}

#[cfg(test)]
mod tests {
    use super::is_openable;

    #[test]
    fn only_web_and_mail_links() {
        for ok in [
            "https://snazzy.pro",
            "HTTP://example.com/a?b=c&d",
            "mailto:a@b.c",
        ] {
            assert!(is_openable(ok), "{ok}");
        }
        for bad in [
            "file:///etc/passwd",
            "javascript:alert(1)",
            "C:\\Windows\\system32\\calc.exe",
            "snazzy-project://x/",
            "https://a.b/\nrm",
            "",
        ] {
            assert!(!is_openable(bad), "{bad}");
        }
    }
}
