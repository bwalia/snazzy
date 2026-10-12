//! docs/specs/settings.md against the Swift fixtures.

mod common;

use common::{assert_same, bytes, json, s, text};
use snazzy_core::json::{Style, write_value};
use snazzy_core::settings::{AppSettings, ProviderKind, SettingsPreset, preset_file_name};

/// Same JSON text (serde_json's Value tells 14 from 14.0; Swift doesn't).
fn same(a: &impl serde::Serialize, b: &serde_json::Value) -> bool {
    snazzy_core::json::to_string(a, Style::COMPACT).unwrap() == write_value(b, Style::COMPACT)
}

#[test]
fn defaults_and_tolerant_reading() {
    let cases = json("settings.json");
    assert!(same(&AppSettings::default(), &cases["default"]));
    assert_eq!(
        serde_json::from_value::<AppSettings>(cases["default"].clone()).unwrap(),
        AppSettings::default()
    );
    for c in cases["partial"].as_array().unwrap() {
        let input = s(&c[0]);
        let decoded: AppSettings =
            serde_json::from_str(input).unwrap_or_else(|e| panic!("{input}: {e}"));
        assert!(same(&decoded, &c[1]), "{input}");
        // Compact, sorted, as SettingsStore would write it with sorted keys.
        assert_eq!(decoded.to_json(), write_value(&c[1], Style::COMPACT));
    }
    for input in cases["invalid"].as_array().unwrap() {
        assert!(
            serde_json::from_str::<AppSettings>(s(input)).is_err(),
            "{input}"
        );
    }
    for c in cases["runsOnThisMac"].as_array().unwrap() {
        let settings = AppSettings {
            ollama_base_url: s(&c[0]).into(),
            ..AppSettings::default()
        };
        assert_eq!(
            settings
                .runs_on_this_computer(ProviderKind::Ollama)
                .to_string(),
            s(&c[1]),
            "{}",
            s(&c[0])
        );
        assert_eq!(
            settings.recipient_name(ProviderKind::Ollama),
            s(&c[2]),
            "{}",
            s(&c[0])
        );
    }
    assert!(!AppSettings::default().runs_on_this_computer(ProviderKind::Anthropic));
}

#[test]
fn presets_round_trip() {
    let preset: SettingsPreset = serde_json::from_slice(&bytes("preset.json")).unwrap();
    assert_eq!(preset.app, Some(AppSettings::default()));
    assert_same("preset.json", &preset.to_json(), &text("preset.json"));
    for c in json("preset-cases.json").as_array().unwrap() {
        assert_eq!(preset_file_name(s(&c[0])), s(&c[1]));
    }
}
