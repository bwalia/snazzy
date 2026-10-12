//! Frames: a 4-byte big-endian length, then that many bytes of JSON (at most
//! `MAX_FRAME`). A message this version doesn't know is skipped (its sender
//! times out) rather than closing the link; an oversized length is an error.

use snazzy_core::json;

use crate::messages::RemoteMessage;
use crate::{MAX_FRAME, RemoteError};

/// The JSON of a message (compact, sorted keys, `\/`), as in the fixtures.
pub fn encode_json(message: &RemoteMessage) -> Result<Vec<u8>, RemoteError> {
    json::to_vec(message, json::Style::COMPACT).map_err(|e| RemoteError(e.to_string()))
}

pub fn encode_frame(message: &RemoteMessage) -> Result<Vec<u8>, RemoteError> {
    let body = encode_json(message)?;
    if body.len() > MAX_FRAME {
        return Err(RemoteError("Message too large.".into()));
    }
    let mut out = (body.len() as u32).to_be_bytes().to_vec();
    out.extend_from_slice(&body);
    Ok(out)
}

/// Accumulates bytes and returns complete messages.
#[derive(Debug, Default, Clone)]
pub struct Reader {
    buffer: Vec<u8>,
}

impl Reader {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn append(&mut self, data: &[u8]) -> Result<Vec<RemoteMessage>, RemoteError> {
        self.buffer.extend_from_slice(data);
        let mut out = Vec::new();
        let mut start = 0;
        while self.buffer.len() - start >= 4 {
            let header: [u8; 4] = self.buffer[start..start + 4].try_into().expect("4 bytes");
            let length = u32::from_be_bytes(header) as usize;
            if length > MAX_FRAME {
                return Err(RemoteError("Message too large.".into()));
            }
            if self.buffer.len() - start < 4 + length {
                break;
            }
            let body = &self.buffer[start + 4..start + 4 + length];
            if let Ok(message) = serde_json::from_slice::<RemoteMessage>(body) {
                out.push(message);
            }
            start += 4 + length;
        }
        self.buffer.drain(..start);
        Ok(out)
    }

    /// Bytes waiting for the rest of their frame.
    pub fn pending(&self) -> usize {
        self.buffer.len()
    }
}
