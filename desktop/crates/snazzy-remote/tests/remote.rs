//! docs/specs/remote.md against the fixtures the Swift tests write
//! (RemoteTests/RemoteSpecFixtureTests.swift).

use std::path::PathBuf;

use serde_json::Value;
use snazzy_core::b64;
use snazzy_remote::framing::encode_json;
use snazzy_remote::{
    MAX_FRAME, PairingInvite, PrompterAction, Reader, RemoteCommand, RemoteMessage, RemoteStatus,
    SERVICE_TYPE, VERSION, device_identity, encode_frame, pairing_identity, proof, verify,
    watch_allows,
};

fn fixture(name: &str) -> Vec<u8> {
    std::fs::read(
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../../docs/specs/fixtures")
            .join(name),
    )
    .unwrap()
}

fn cases() -> Value {
    serde_json::from_slice(&fixture("remote-cases.json")).unwrap()
}

fn s(v: &Value) -> &str {
    v.as_str().unwrap()
}

#[test]
fn constants_match() {
    let c = cases();
    assert_eq!(c["version"].as_i64(), Some(VERSION));
    assert_eq!(s(&c["serviceType"]), SERVICE_TYPE);
    assert_eq!(c["maxFrame"].as_u64(), Some(MAX_FRAME as u64));
    assert_eq!(s(&c["pairingIdentity"]), pairing_identity("host-abc"));
    assert_eq!(s(&c["deviceIdentity"]), device_identity("dev-1234"));
}

#[test]
fn every_message_round_trips_byte_for_byte() {
    let c = cases();
    let messages = c["messages"].as_array().unwrap();
    let mut decoded = Vec::new();
    for m in messages {
        let json = s(&m["json"]);
        let message: RemoteMessage =
            serde_json::from_str(json).unwrap_or_else(|e| panic!("{}: {e}", s(&m["name"])));
        assert_eq!(
            String::from_utf8(encode_json(&message).unwrap()).unwrap(),
            json,
            "{}",
            s(&m["name"])
        );
        if let RemoteMessage::Command { command, .. } = &message {
            assert_eq!(
                Some(watch_allows(command)),
                m["watchAllows"].as_bool(),
                "{}",
                s(&m["name"])
            );
        }
        decoded.push(message);
    }
    // Every command and prompter action is covered.
    let commands: Vec<&RemoteCommand> = decoded
        .iter()
        .filter_map(|m| {
            if let RemoteMessage::Command { command, .. } = m {
                Some(command)
            } else {
                None
            }
        })
        .collect();
    assert_eq!(commands.len(), 17);
    assert!(commands.contains(&&RemoteCommand::Prompter {
        action: PrompterAction::Seek { position: 0.5 }
    }));

    // The framed stream (with one message from a newer version) reads the same,
    // fed in awkward pieces, and the frames we write are the same bytes.
    let stream = fixture("remote-frames.bin");
    let mut reader = Reader::new();
    let mut read = Vec::new();
    for chunk in stream.chunks(97) {
        read.extend(reader.append(chunk).unwrap());
    }
    assert_eq!(reader.pending(), 0);
    assert_eq!(read, decoded);
    let unknown = s(&c["unknown"][0]).as_bytes();
    let mut ours = Vec::new();
    for m in &decoded {
        ours.extend(encode_frame(m).unwrap());
        if matches!(m, RemoteMessage::Status { status } if status.prompter.is_some()) {
            ours.extend((unknown.len() as u32).to_be_bytes());
            ours.extend(unknown);
        }
    }
    assert_eq!(ours, stream);
}

#[test]
fn status_reads_with_and_without_optional_fields() {
    let full: RemoteStatus = serde_json::from_slice(&fixture("remote-status.json")).unwrap();
    assert!(full.is_recording());
    assert_eq!(full.prompter.as_ref().unwrap().words_per_minute, 160.0);
    let p = full.prompter.clone().unwrap();
    assert_eq!(p.progress_after(30.0, 0), 0.25);
    assert!((p.progress_after(3.0, 80) - 0.35).abs() < 1e-12);
    // A newer host may add fields: ignored.
    let newer: RemoteStatus =
        serde_json::from_str(r#"{"hostName":"x","recording":"idle","elapsed":0,"micLevel":0,"source":"","slideCount":0,"warnings":[],"later":{"a":1}}"#).unwrap();
    assert_eq!(newer, RemoteStatus::idle("x"));
}

#[test]
fn oversized_frames_are_refused() {
    let mut reader = Reader::new();
    assert!(
        reader
            .append(&((MAX_FRAME as u32 + 1).to_be_bytes()))
            .is_err()
    );
    let mut reader = Reader::new();
    assert!(
        reader
            .append(&(MAX_FRAME as u32).to_be_bytes())
            .unwrap()
            .is_empty()
    );
}

#[test]
fn proofs_match() {
    let c = cases();
    for p in c["proofs"].as_array().unwrap() {
        let key = b64::decode(s(&p["key"])).unwrap();
        let expected = b64::decode(s(&p["proof"])).unwrap();
        let id = s(&p["deviceID"]);
        assert_eq!(proof(id, &key).to_vec(), expected, "{id:?}");
        assert!(verify(Some(&expected), id, &key));
        assert!(!verify(Some(&expected), &format!("{id}x"), &key));
        assert!(!verify(None, id, &key));
    }
}

#[test]
fn pairing_links_match() {
    let c = cases();
    for i in c["invites"].as_array().unwrap() {
        let invite = PairingInvite {
            host_id: s(&i["hostID"]).into(),
            host_name: s(&i["hostName"]).into(),
            secret: b64::decode(s(&i["secret"])).unwrap(),
            address: i.get("address").map(|a| s(a).to_string()),
        };
        assert_eq!(invite.url(), s(&i["url"]));
        assert_eq!(PairingInvite::parse(&invite.url()), Some(invite));
    }
    for p in c["pairing"].as_array().unwrap() {
        let url = s(&p["url"]);
        let parsed = PairingInvite::parse(url);
        match p.get("hostID") {
            None => assert_eq!(parsed, None, "{url}"),
            Some(h) => {
                let parsed = parsed.unwrap_or_else(|| panic!("{url} should parse"));
                assert_eq!(parsed.host_id, s(h), "{url}");
                assert_eq!(parsed.host_name, s(&p["hostName"]), "{url}");
                assert_eq!(b64::encode(&parsed.secret), s(&p["secret"]), "{url}");
                assert_eq!(parsed.address.as_deref(), p.get("address").map(s), "{url}");
            }
        }
    }
}
