//! Snazzy Pro for Windows and Linux: the Tauri shell. The work happens in the
//! `snazzy-*` crates; commands here are thin wrappers the UI calls.

mod chat;
mod decks;

use serde::Serialize;
use tauri::Manager;

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
    let opened = decks::file_to_open(std::env::args());
    tauri::Builder::default()
        .manage(chat::ChatState::new())
        .manage(decks::DeckState::new(opened))
        // Projects for the Builder, the library and the Present window: only
        // links handed out this run are served (snazzy_core::preview).
        .register_asynchronous_uri_scheme_protocol(
            snazzy_core::preview::SCHEME,
            |ctx, request, responder| {
                let app = ctx.app_handle().clone();
                let path = request.uri().path().to_string();
                tauri::async_runtime::spawn_blocking(move || {
                    let r = app.state::<decks::DeckState>().serve(&path);
                    let mut response = tauri::http::Response::builder().status(r.status);
                    for (name, value) in r.headers {
                        response = response.header(name, value);
                    }
                    let response = response
                        .body(r.body)
                        .unwrap_or_else(|_| tauri::http::Response::new(b"Bad response".to_vec()));
                    responder.respond(response);
                });
            },
        )
        .invoke_handler(tauri::generate_handler![
            app_info,
            chat::chat_status,
            chat::set_chat_settings,
            chat::agree_to_cloud,
            chat::set_anthropic_key,
            chat::list_models,
            chat::new_conversation,
            chat::stop_chat,
            chat::send_chat,
            decks::deck_library,
            decks::search_slides,
            decks::open_deck,
            decks::open_sample,
            decks::new_deck,
            decks::deck_outline,
            decks::save_deck_outline,
            decks::set_deck_details,
            decks::allow_deck_internet,
            decks::delete_deck,
            decks::import_share,
            decks::opened_file,
            decks::import_opened_file,
            decks::export_deck,
            decks::show_downloads,
            decks::open_link,
            decks::displays,
            decks::present_open,
            decks::present_state,
            decks::present_go,
            decks::present_fullscreen,
            decks::present_close,
            decks::deck_repos,
            decks::add_deck_repo,
            decks::remove_deck_repo,
            decks::list_repo_decks,
            decks::add_repo_deck,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Snazzy Pro");
}
