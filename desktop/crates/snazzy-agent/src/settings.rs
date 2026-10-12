//! Whether content sent to a model stays on this computer (Swift
//! `AppSettings.runsOnThisMac`). Decided from the configured host, because
//! Ollama can run on another computer.

use crate::types::ProviderKind;

/// True when the Ollama base URL points at this computer.
pub fn is_this_computer(base_url: &str) -> bool {
    let host = reqwest::Url::parse(base_url)
        .ok()
        .and_then(|u| {
            u.host_str()
                .map(|h| h.trim_matches(['[', ']']).to_lowercase())
        })
        .unwrap_or_default();
    ["localhost", "127.0.0.1", "::1"].contains(&host.as_str())
}

/// Whether what's sent to `kind` stays on this computer. Ask before anything
/// leaves when this is false.
pub fn runs_on_this_computer(kind: ProviderKind, ollama_base_url: &str) -> bool {
    match kind {
        ProviderKind::Ollama => is_this_computer(ollama_base_url),
        other => other.is_local(),
    }
}

/// Who receives what's sent to `kind`, for "Send … to X?" prompts and badges.
pub fn recipient_name(kind: ProviderKind, ollama_base_url: &str) -> String {
    if kind != ProviderKind::Ollama || runs_on_this_computer(kind, ollama_base_url) {
        return kind.display_name().to_string();
    }
    let host = reqwest::Url::parse(ollama_base_url)
        .ok()
        .and_then(|u| u.host_str().map(|h| h.trim_matches(['[', ']']).to_string()))
        .unwrap_or_else(|| ollama_base_url.to_string());
    format!("Ollama at {host}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decides_from_the_host() {
        for local in [
            "http://localhost:11434",
            "http://LOCALHOST:11434/",
            "http://127.0.0.1:11434",
            "http://[::1]:11434",
        ] {
            assert!(
                runs_on_this_computer(ProviderKind::Ollama, local),
                "{local}"
            );
        }
        for remote in [
            "http://192.168.1.20:11434",
            "http://gpu-box.local:11434",
            "not a url",
        ] {
            assert!(
                !runs_on_this_computer(ProviderKind::Ollama, remote),
                "{remote}"
            );
        }
        // The provider type never decides on its own.
        assert!(!runs_on_this_computer(
            ProviderKind::Anthropic,
            "http://localhost:11434"
        ));
        assert_eq!(
            recipient_name(ProviderKind::Ollama, "http://192.168.1.20:11434"),
            "Ollama at 192.168.1.20"
        );
        assert_eq!(
            recipient_name(ProviderKind::Ollama, "http://localhost:11434"),
            "Ollama (local)"
        );
        assert_eq!(recipient_name(ProviderKind::Anthropic, ""), "Anthropic");
    }
}
