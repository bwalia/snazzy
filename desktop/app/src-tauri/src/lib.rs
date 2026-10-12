//! Snazzy Pro for Windows and Linux: the Tauri shell. The work happens in the
//! `snazzy-*` crates; commands here are thin wrappers the UI calls.

use serde::Serialize;

#[derive(Serialize)]
struct AppInfo {
    version: &'static str,
    platform: &'static str,
}

#[tauri::command]
fn app_info() -> AppInfo {
    AppInfo {
        version: env!("CARGO_PKG_VERSION"),
        platform: std::env::consts::OS,
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![app_info])
        .run(tauri::generate_context!())
        .expect("error while running Snazzy Pro");
}
