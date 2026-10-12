//! docs/specs/recordings.md against the Swift fixtures.

mod common;

use common::{assert_same, bytes, text};
use snazzy_core::timeline::{self, Aspect, Timeline};

#[test]
fn timeline_round_trips_byte_for_byte() {
    for name in ["timeline.json", "timeline-minimal.json"] {
        let t = Timeline::parse(&bytes(name)).unwrap();
        assert_same(name, &t.to_json(), &text(name));
    }
    let t = Timeline::parse(&bytes("timeline.json")).unwrap();
    assert_eq!(t.inset.title_slide_size, Some(0.5));
    assert_eq!(t.camera_latency_ms, Some(41.0));
    assert_eq!(
        Timeline::median_latency_ms(&[0.031, 0.034, 0.0405, 0.05]),
        Some(41.0)
    );
    assert_eq!(
        t.inset.background,
        serde_json::json!({"blur": {"strength": 0.6}})
    );
    let minimal = Timeline::parse(&bytes("timeline-minimal.json")).unwrap();
    assert_eq!(minimal.inset.aspect, Aspect::Fit);
    assert_eq!(minimal.camera_latency_ms, None);
    assert_eq!(minimal.note, timeline::NOTE);
}

#[test]
fn chapters_match() {
    let t = Timeline::parse(&bytes("timeline.json")).unwrap();
    let marks = timeline::marks_from_timeline(&t.markers, t.composite_starts_at_seconds);
    let vtt = timeline::chapters_vtt(&marks, t.duration_seconds, 1.5).unwrap();
    assert_same("chapters.vtt", &vtt, &text("chapters.vtt"));
    assert_eq!(
        timeline::chapters_file_name("presentation-20260102-030405.mov"),
        "presentation-20260102-030405.chapters.vtt"
    );
    let one = [timeline::Mark {
        at: 1.0,
        title: "Only".into(),
    }];
    assert_eq!(timeline::chapters_vtt(&one, 10.0, 1.5), None);
}

#[test]
fn old_and_partial_timelines_still_read() {
    let t = Timeline::parse(br#"{"duration_seconds": 12, "inset": {"corner": "topLeft", "aspect": "fit"}, "future": [1]}"#).unwrap();
    assert_eq!(t.duration_seconds, 12.0);
    assert_eq!(t.inset.corner, "topLeft");
    assert_eq!(t.inset.size, 0.28);
    assert_eq!(t.inset.aspect, Aspect::Fit);
    assert_eq!(t.camera_latency(), 0.0);
}
