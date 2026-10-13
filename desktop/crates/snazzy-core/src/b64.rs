//! Base64 as Foundation writes and reads it (`Data.base64EncodedString()`,
//! `Data(base64Encoded:)`): the standard alphabet with `=` padding, strict on
//! decoding. Also the URL-safe form the pairing link uses. Serde helpers encode
//! `Vec<u8>` fields the way Swift's `JSONEncoder` encodes `Data`.

const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

pub fn encode(data: &[u8]) -> String {
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let b = [
            chunk[0],
            *chunk.get(1).unwrap_or(&0),
            *chunk.get(2).unwrap_or(&0),
        ];
        let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        out.push(ALPHABET[(n >> 18) as usize & 63] as char);
        out.push(ALPHABET[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 {
            ALPHABET[(n >> 6) as usize & 63] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            ALPHABET[n as usize & 63] as char
        } else {
            '='
        });
    }
    out
}

fn value(c: u8) -> Option<u32> {
    match c {
        b'A'..=b'Z' => Some(u32::from(c - b'A')),
        b'a'..=b'z' => Some(u32::from(c - b'a') + 26),
        b'0'..=b'9' => Some(u32::from(c - b'0') + 52),
        b'+' => Some(62),
        b'/' => Some(63),
        _ => None,
    }
}

/// Strict: length a multiple of 4, padding only at the end, no whitespace.
pub fn decode(text: &str) -> Option<Vec<u8>> {
    let bytes = text.as_bytes();
    if bytes.len() % 4 != 0 {
        return None;
    }
    let mut out = Vec::with_capacity(bytes.len() / 4 * 3);
    let quads = bytes.len() / 4;
    for (i, quad) in bytes.chunks(4).enumerate() {
        let pad = quad.iter().rev().take_while(|&&c| c == b'=').count();
        if pad > 2 || (pad > 0 && i + 1 != quads) {
            return None;
        }
        let mut n = 0u32;
        for &c in &quad[..4 - pad] {
            n = (n << 6) | value(c)?;
        }
        n <<= 6 * pad as u32;
        out.push((n >> 16) as u8);
        if pad < 2 {
            out.push((n >> 8) as u8);
        }
        if pad < 1 {
            out.push(n as u8);
        }
    }
    Some(out)
}

/// URL-safe, without padding (`-` for `+`, `_` for `/`).
pub fn encode_url(data: &[u8]) -> String {
    encode(data)
        .replace('+', "-")
        .replace('/', "_")
        .replace('=', "")
}

/// Accepts the URL-safe and the standard alphabet, with or without padding.
pub fn decode_url(text: &str) -> Option<Vec<u8>> {
    let mut s = text.replace('-', "+").replace('_', "/");
    while s.chars().count() % 4 != 0 {
        s.push('=');
    }
    decode(&s)
}

/// `#[serde(with = "snazzy_core::b64::serde_bytes")]` for `Vec<u8>` fields.
pub mod serde_bytes {
    use serde::{Deserialize, Deserializer, Serializer, de::Error};

    pub fn serialize<S: Serializer>(data: &[u8], s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&super::encode(data))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<u8>, D::Error> {
        let text = String::deserialize(d)?;
        super::decode(&text).ok_or_else(|| D::Error::custom("invalid base64"))
    }
}

/// The same for `Option<Vec<u8>>` (absent when `None`; pair with
/// `skip_serializing_if = "Option::is_none"` and `default`).
pub mod serde_opt_bytes {
    use serde::{Deserialize, Deserializer, Serializer, de::Error};

    pub fn serialize<S: Serializer>(data: &Option<Vec<u8>>, s: S) -> Result<S::Ok, S::Error> {
        match data {
            Some(d) => s.serialize_str(&super::encode(d)),
            None => s.serialize_none(),
        }
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Option<Vec<u8>>, D::Error> {
        match Option::<String>::deserialize(d)? {
            Some(text) => super::decode(&text)
                .map(Some)
                .ok_or_else(|| D::Error::custom("invalid base64")),
            None => Ok(None),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips() {
        for n in 0..40u8 {
            let data: Vec<u8> = (0..n)
                .map(|i| i.wrapping_mul(37).wrapping_add(250))
                .collect();
            assert_eq!(decode(&encode(&data)).unwrap(), data);
            assert_eq!(decode_url(&encode_url(&data)).unwrap(), data);
        }
        assert_eq!(encode(&[1, 2, 3, 250]), "AQID+g==");
        assert_eq!(decode("AQID+g="), None);
        assert_eq!(decode("AQ=D"), None);
        assert_eq!(decode("AQID+g==AQID"), None);
        assert_eq!(decode("not*base64=="), None);
    }
}
