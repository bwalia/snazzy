//! Keys and proofs. The link is TLS 1.2 with a pre-shared key
//! (`TLS_PSK_WITH_AES_128_GCM_SHA256`); identities are `pair:<hostID>` for the
//! one-time pairing secret and `dev:<deviceID>` for a paired device's own key.
//! The handshake only shows the device holds *some* accepted key, so `hello`
//! carries an HMAC-SHA256 of the device ID keyed with the key it claims.

use hmac::{Hmac, Mac};
use sha2::Sha256;

type HmacSha256 = Hmac<Sha256>;

pub fn pairing_identity(host_id: &str) -> String {
    format!("pair:{host_id}")
}

pub fn device_identity(device_id: &str) -> String {
    format!("dev:{device_id}")
}

/// HMAC-SHA256(key, UTF-8 device ID).
pub fn proof(device_id: &str, key: &[u8]) -> [u8; 32] {
    let mut mac = HmacSha256::new_from_slice(key).expect("HMAC takes keys of any length");
    mac.update(device_id.as_bytes());
    mac.finalize().into_bytes().into()
}

/// Constant-time check of a `hello` proof; a missing proof never verifies.
pub fn verify(proof: Option<&[u8]>, device_id: &str, key: &[u8]) -> bool {
    let Some(proof) = proof else { return false };
    let mut mac = HmacSha256::new_from_slice(key).expect("HMAC takes keys of any length");
    mac.update(device_id.as_bytes());
    mac.verify_slice(proof).is_ok()
}
