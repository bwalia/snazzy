//! The pairing QR code: `snazzypro://pair?v=2&h=<hostID>&n=<host name>&s=<secret>&a=<addresses>`.
//! `s` is the 32-byte pairing secret in URL-safe base64 without padding; `a`
//! (optional) is "ip:port,ip:port" for when Bonjour can't find the host.

use snazzy_core::b64;

use crate::VERSION;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairingInvite {
    pub host_id: String,
    pub host_name: String,
    pub secret: Vec<u8>,
    pub address: Option<String>,
}

/// What `URLComponents` leaves unescaped in a query value: the query characters
/// minus `&`, `=` and `#`.
fn encode_value(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b"-._~!$'()*+,;:@/?".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

fn decode_value(s: &str) -> Option<String> {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = std::str::from_utf8(bytes.get(i + 1..i + 3)?).ok()?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

impl PairingInvite {
    pub fn url(&self) -> String {
        let mut s = format!(
            "snazzypro://pair?v={VERSION}&h={}&n={}&s={}",
            encode_value(&self.host_id),
            encode_value(&self.host_name),
            b64::encode_url(&self.secret)
        );
        if let Some(a) = &self.address {
            s += &format!("&a={}", encode_value(a));
        }
        s
    }

    /// None unless it's a `snazzypro://pair` link with a host ID and a 32-byte secret.
    pub fn parse(url: &str) -> Option<PairingInvite> {
        if !url.bytes().all(|b| b.is_ascii_graphic()) {
            return None;
        }
        let rest = url.strip_prefix("snazzypro://")?;
        let rest = rest.split('#').next().unwrap_or("");
        let (before_query, query) = rest.split_once('?').unwrap_or((rest, ""));
        let authority = before_query.split('/').next().unwrap_or("");
        let host = authority.rsplit_once('@').map_or(authority, |(_, h)| h);
        if host.split(':').next() != Some("pair") {
            return None;
        }
        let mut items: Vec<(String, Option<String>)> = Vec::new();
        for item in query.split('&') {
            let (name, value) = match item.split_once('=') {
                Some((n, v)) => (n, Some(decode_value(v)?)),
                None => (item, None),
            };
            items.push((decode_value(name)?, value));
        }
        let v = |n: &str| {
            items
                .iter()
                .find(|(name, _)| name == n)
                .and_then(|(_, v)| v.clone())
        };
        let host_id = v("h").filter(|h| !h.is_empty())?;
        let secret = v("s")
            .and_then(|s| b64::decode_url(&s))
            .filter(|s| s.len() == 32)?;
        Some(PairingInvite {
            host_id,
            host_name: v("n").unwrap_or_else(|| "Mac".into()),
            secret,
            address: v("a"),
        })
    }
}
