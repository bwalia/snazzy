//! docs/specs/voice-notes.md against the Swift fixture.

mod common;

use common::{assert_same, bytes, text};
use snazzy_core::iso8601::Date;
use snazzy_core::voice_notes::{
    self, Mark, Segment, VoiceNote, VoiceNoteStore, clock, parse_transcription, title_from,
    transcription_request,
};

#[test]
fn fixture_round_trips_byte_for_byte() {
    let note = VoiceNote::parse(&bytes("voice-note.json")).unwrap();
    assert_same("voice-note.json", &note.to_json(), &text("voice-note.json"));
    assert_eq!(note.device, "Mac");
    assert_eq!(note.segments.len(), 3);
    assert_eq!(
        note.marks,
        vec![Mark {
            at: 4.2,
            label: "Idea".into()
        }]
    );
    assert!(note.transcript_matches_segments());
}

#[test]
fn titles_like_the_mac() {
    assert_eq!(
        title_from("okay, ideas for the spring launch. More later"),
        "Okay, ideas for the spring launch"
    );
    assert_eq!(
        title_from("one two three four five six seven eight nine"),
        "One two three four five six seven"
    );
    assert_eq!(title_from("  "), "");
    let note = VoiceNote::parse(&bytes("voice-note.json")).unwrap();
    assert_eq!(note.display_title(), "Okay, ideas for the spring launch");
}

#[test]
fn search_like_the_mac() {
    let mut note = VoiceNote::parse(&bytes("voice-note.json")).unwrap();
    assert!(note.matches("friday DEMO"));
    assert!(note.matches("launch"));
    assert!(!note.matches("friday budget"));
    assert!(note.matches(""));
    note.transcript = "Un café à Montréal".into();
    assert!(note.matches("cafe montreal"));
}

#[test]
fn tolerant_reading() {
    let note = VoiceNote::parse(br#"{"format":"snazzy-voice-note","id":"abc-1"}"#).unwrap();
    assert!(note.transcript.is_empty() && note.segments.is_empty());
    assert_eq!(note.transcribed_by, "none");
    assert_eq!(note.updated_at, Some(note.created_at));
    assert!(VoiceNote::parse(br#"{"format":"other","id":"abc"}"#).is_err());
    assert!(VoiceNote::parse(br#"{"format":"snazzy-voice-note","version":2,"id":"abc"}"#).is_err());
}

#[test]
fn markdown_like_the_mac() {
    let note = VoiceNote::parse(&bytes("voice-note.json")).unwrap();
    let md = note.markdown();
    assert!(md.starts_with("# Okay, ideas for the spring launch\n"));
    assert!(md.contains("- 0:04 Idea: “We could run a live demo every Friday.”"));
    assert!(md.contains(
        "**0:00** Okay, ideas for the spring launch. We could run a live demo every Friday.\n"
    ));
    assert!(md.contains("**0:09** And send the slides to everyone who joins."));
    let mut edited = note.clone();
    edited.transcript = "Rewritten by hand.".into();
    assert!(
        edited
            .markdown()
            .contains("## Notes\n\nRewritten by hand.\n")
    );
    assert_eq!(clock(0.0), "0:00");
    assert_eq!(clock(75.9), "1:15");
    assert_eq!(clock(3725.0), "1:02:05");
}

#[test]
fn store_round_trip_and_paths() {
    let dir = tempfile::tempdir().unwrap();
    let store = VoiceNoteStore::new(dir.path());
    let now = Date::parse("2026-01-02T03:04:05Z").unwrap();
    let mut a = VoiceNote::new("first", now, "Linux");
    store
        .put_audio(&mut a, b"not really audio", "webm")
        .unwrap();
    store.save(&mut a, now).unwrap();
    let mut b = VoiceNote::new(
        "second",
        Date::from_unix(now.unix() + 60).unwrap(),
        "Windows",
    );
    store.save(&mut b, now).unwrap();
    std::fs::create_dir_all(dir.path().join("not a note")).unwrap();
    let ids: Vec<String> = store.all().into_iter().map(|n| n.id).collect();
    assert_eq!(ids, ["second", "first"]);
    assert_eq!(a.audio.as_deref(), Some("audio.webm"));
    assert!(store.audio_path(&a).unwrap().exists());
    store.delete("first").unwrap();
    assert_eq!(store.all().len(), 1);
    assert!(store.folder("../escape").is_err());
    let mut evil = b.clone();
    evil.audio = Some("../../etc/passwd".into());
    assert!(store.audio_path(&evil).is_none());
    assert!(store.put_audio(&mut b, b"x", "../x").is_err());
    // What the Mac reads back.
    let saved = std::fs::read(dir.path().join("second/note.json")).unwrap();
    assert!(
        String::from_utf8(saved)
            .unwrap()
            .contains("\"device\" : \"Windows\"")
    );
    assert_eq!(
        voice_notes::audio_extension("audio/webm;codecs=opus"),
        "webm"
    );
    assert_eq!(voice_notes::audio_extension("audio/ogg"), "ogg");
}

#[test]
fn transcription_server_requests() {
    let r = transcription_request(
        "http://localhost:8080/",
        b"AUDIO",
        "audio.webm",
        "",
        Some("en-GB"),
        "XYZ",
    )
    .unwrap();
    assert_eq!(r.url, "http://localhost:8080/v1/audio/transcriptions");
    assert_eq!(r.content_type, "multipart/form-data; boundary=XYZ");
    let body = String::from_utf8(r.body).unwrap();
    assert!(body.contains("name=\"model\"\r\n\r\nwhisper-1\r\n"));
    assert!(body.contains("name=\"response_format\"\r\n\r\nverbose_json\r\n"));
    assert!(body.contains("name=\"language\"\r\n\r\nen\r\n"));
    assert!(body.contains(
        "filename=\"audio.webm\"\r\nContent-Type: audio/webm\r\n\r\nAUDIO\r\n--XYZ--\r\n"
    ));
    let r = transcription_request(
        "http://127.0.0.1:8080/inference",
        b"",
        "audio.wav",
        "base.en",
        None,
        "B",
    )
    .unwrap();
    assert_eq!(r.url, "http://127.0.0.1:8080/inference");
    assert!(transcription_request("localhost:8080", b"", "a.webm", "", None, "B").is_err());
}

#[test]
fn transcription_answers() {
    let verbose = br#"{"text":" Hello there. Next idea.","segments":[{"start":0.0,"end":1.2,"text":" Hello there."},{"start":1.5,"end":3.0,"text":" Next idea."}]}"#;
    assert_eq!(
        parse_transcription(verbose, 3.0).unwrap(),
        vec![
            Segment {
                start: 0.0,
                end: 1.2,
                text: "Hello there.".into()
            },
            Segment {
                start: 1.5,
                end: 3.0,
                text: "Next idea.".into()
            },
        ]
    );
    let plain = br#"{"text":"Just text."}"#;
    assert_eq!(parse_transcription(plain, 4.0).unwrap()[0].end, 4.0);
    assert!(parse_transcription(br#"{"error":{"message":"model not found"}}"#, 1.0).is_err());
    assert!(parse_transcription(b"<html>", 1.0).is_err());
}
