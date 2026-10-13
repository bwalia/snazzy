//! Where Snazzy Pro keeps its data and recordings on each system.
//!
//! - Windows: `%APPDATA%\Snazzy Pro\` and `Videos\Snazzy Pro\` in the user's profile.
//! - Linux: `$XDG_DATA_HOME/snazzy-pro/` (default `~/.local/share`) and
//!   `$XDG_VIDEOS_DIR/Snazzy Pro/` (from `user-dirs.dirs`, default `~/Videos`).
//! - macOS (development only): `~/Library/Application Support/Snazzy Pro Desktop/` and `~/Movies/`.

use std::path::{Path, PathBuf};

/// Environment lookups, injectable so tests don't depend on the machine.
pub trait Env {
    fn var(&self, key: &str) -> Option<String>;
    fn read(&self, path: &Path) -> Option<String>;
}

/// The real process environment and file system.
pub struct SystemEnv;

impl Env for SystemEnv {
    fn var(&self, key: &str) -> Option<String> {
        std::env::var(key).ok().filter(|v| !v.is_empty())
    }
    fn read(&self, path: &Path) -> Option<String> {
        std::fs::read_to_string(path).ok()
    }
}

/// The folders the app uses.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Folders {
    /// Settings, conversations, presets and backgrounds.
    pub data: PathBuf,
    /// One folder per Builder project.
    pub projects: PathBuf,
    /// `Recordings/` and `Sessions/` live here.
    pub movies: PathBuf,
    /// Where exported files (`.snazzy`) are saved.
    pub downloads: PathBuf,
}

impl Folders {
    pub fn recordings(&self) -> PathBuf {
        self.movies.join("Recordings")
    }
    pub fn sessions(&self) -> PathBuf {
        self.movies.join("Sessions")
    }
}

/// The folders for this system, or None if the home folder can't be found.
pub fn folders() -> Option<Folders> {
    folders_for(std::env::consts::OS, &SystemEnv)
}

/// The folders for `os` ("windows", "linux", "macos") with the given environment.
pub fn folders_for(os: &str, env: &dyn Env) -> Option<Folders> {
    let (data, videos, downloads) = match os {
        "windows" => {
            let appdata = env.var("APPDATA").map(PathBuf::from)?;
            let profile = env.var("USERPROFILE").map(PathBuf::from)?;
            (
                appdata.join("Snazzy Pro"),
                profile.join("Videos"),
                profile.join("Downloads"),
            )
        }
        "macos" => {
            let home = env.var("HOME").map(PathBuf::from)?;
            (
                home.join("Library/Application Support/Snazzy Pro Desktop"),
                home.join("Movies"),
                home.join("Downloads"),
            )
        }
        _ => {
            let home = env.var("HOME").map(PathBuf::from)?;
            let data_home = env
                .var("XDG_DATA_HOME")
                .map(PathBuf::from)
                .filter(|p| p.is_absolute())
                .unwrap_or_else(|| home.join(".local/share"));
            (
                data_home.join("snazzy-pro"),
                xdg_dir(&home, env, "XDG_VIDEOS_DIR", "Videos"),
                xdg_dir(&home, env, "XDG_DOWNLOAD_DIR", "Downloads"),
            )
        }
    };
    Some(Folders {
        projects: data.join("Projects"),
        data,
        movies: videos.join("Snazzy Pro"),
        downloads,
    })
}

/// `$<key>` (e.g. `XDG_VIDEOS_DIR`), then `<key>` in `user-dirs.dirs`, then
/// `~/<fallback>`.
fn xdg_dir(home: &Path, env: &dyn Env, key: &str, fallback: &str) -> PathBuf {
    if let Some(v) = env.var(key).map(PathBuf::from).filter(|p| p.is_absolute()) {
        return v;
    }
    let config = env
        .var("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| home.join(".config"));
    if let Some(text) = env.read(&config.join("user-dirs.dirs")) {
        for line in text.lines() {
            let line = line.trim();
            if let Some(value) = line.strip_prefix(key).and_then(|l| l.strip_prefix('=')) {
                let value = value.trim().trim_matches('"');
                let path = match value.strip_prefix("$HOME") {
                    Some(rest) => home.join(rest.trim_start_matches('/')),
                    None => PathBuf::from(value),
                };
                // A folder equal to home means "not set".
                if path.is_absolute() && path != home {
                    return path;
                }
            }
        }
    }
    home.join(fallback)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    struct FakeEnv {
        vars: HashMap<&'static str, &'static str>,
        files: HashMap<PathBuf, &'static str>,
    }

    impl Env for FakeEnv {
        fn var(&self, key: &str) -> Option<String> {
            self.vars.get(key).map(|v| v.to_string())
        }
        fn read(&self, path: &Path) -> Option<String> {
            self.files.get(path).map(|v| v.to_string())
        }
    }

    fn env(vars: &[(&'static str, &'static str)], files: &[(&str, &'static str)]) -> FakeEnv {
        FakeEnv {
            vars: vars.iter().copied().collect(),
            files: files.iter().map(|(p, t)| (PathBuf::from(p), *t)).collect(),
        }
    }

    #[test]
    fn windows_uses_appdata_and_videos() {
        let e = env(
            &[
                ("APPDATA", r"C:\Users\ana\AppData\Roaming"),
                ("USERPROFILE", r"C:\Users\ana"),
            ],
            &[],
        );
        let f = folders_for("windows", &e).unwrap();
        assert_eq!(
            f.data,
            PathBuf::from(r"C:\Users\ana\AppData\Roaming").join("Snazzy Pro")
        );
        assert_eq!(f.projects, f.data.join("Projects"));
        assert_eq!(
            f.movies,
            PathBuf::from(r"C:\Users\ana")
                .join("Videos")
                .join("Snazzy Pro")
        );
        assert_eq!(f.recordings(), f.movies.join("Recordings"));
        assert_eq!(
            f.downloads,
            PathBuf::from(r"C:\Users\ana").join("Downloads")
        );
    }

    // Unix paths aren't absolute on Windows, so these run on Linux and macOS.
    #[cfg(not(windows))]
    #[test]
    fn linux_defaults() {
        let f = folders_for("linux", &env(&[("HOME", "/home/ana")], &[])).unwrap();
        assert_eq!(f.data, PathBuf::from("/home/ana/.local/share/snazzy-pro"));
        assert_eq!(f.movies, PathBuf::from("/home/ana/Videos/Snazzy Pro"));
        assert_eq!(f.downloads, PathBuf::from("/home/ana/Downloads"));
        assert_eq!(
            f.sessions(),
            PathBuf::from("/home/ana/Videos/Snazzy Pro/Sessions")
        );
    }

    #[cfg(not(windows))]
    #[test]
    fn linux_follows_xdg_settings() {
        let dirs = "# written by xdg-user-dirs-update\nXDG_VIDEOS_DIR=\"$HOME/Vídeos\"\nXDG_DOWNLOAD_DIR=\"$HOME/Descargas\"\n";
        let e = env(
            &[("HOME", "/home/ana"), ("XDG_DATA_HOME", "/data/ana")],
            &[("/home/ana/.config/user-dirs.dirs", dirs)],
        );
        let f = folders_for("linux", &e).unwrap();
        assert_eq!(f.data, PathBuf::from("/data/ana/snazzy-pro"));
        assert_eq!(f.movies, PathBuf::from("/home/ana/Vídeos/Snazzy Pro"));
        assert_eq!(f.downloads, PathBuf::from("/home/ana/Descargas"));
        // Relative XDG paths are ignored, as the spec says.
        let e = env(&[("HOME", "/home/ana"), ("XDG_DATA_HOME", "rel")], &[]);
        assert_eq!(
            folders_for("linux", &e).unwrap().data,
            PathBuf::from("/home/ana/.local/share/snazzy-pro")
        );
    }

    #[test]
    fn no_home_no_folders() {
        assert_eq!(folders_for("linux", &env(&[], &[])), None);
        assert_eq!(
            folders_for("windows", &env(&[("APPDATA", r"C:\x")], &[])),
            None
        );
    }
}
