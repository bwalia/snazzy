//! The remote-control protocol between Snazzy Pro (the host) and the iPhone,
//! iPad and Apple Watch apps, which must work unchanged against Windows and
//! Linux. Mirrors Remote/RemoteProtocol.swift, RemoteSecurity.swift and
//! WatchLink.swift. Pure pieces only (no networking yet): messages, framing,
//! the `hello` proof and the pairing link. Spec: docs/specs/remote.md.

pub mod framing;
pub mod messages;
pub mod pairing;
pub mod security;

pub use framing::{Reader, encode_frame};
pub use messages::{
    PrompterAction, PrompterState, RemoteCommand, RemoteMessage, RemoteStatus, watch_allows,
};
pub use pairing::PairingInvite;
pub use security::{device_identity, pairing_identity, proof, verify};

/// 2: `hello` carries a proof of the key behind its claim.
pub const VERSION: i64 = 2;
/// Bonjour service type.
pub const SERVICE_TYPE: &str = "_snazzyremote._tcp";
/// Largest frame body accepted.
pub const MAX_FRAME: usize = 1_000_000;
/// The only cipher suite both sides offer (TLS 1.2, pre-shared key).
pub const CIPHER_SUITE: &str = "TLS_PSK_WITH_AES_128_GCM_SHA256";

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("{0}")]
pub struct RemoteError(pub String);
