//! A tiny HTTP/1.1 server on 127.0.0.1 for provider tests (no real network).

#![allow(dead_code)]

use std::sync::{Arc, Mutex};

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

#[derive(Debug, Clone)]
pub struct Recorded {
    pub method: String,
    pub path: String,
    /// Lower-cased header names.
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Recorded {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.as_str())
    }

    pub fn json(&self) -> serde_json::Value {
        serde_json::from_slice(&self.body).expect("JSON body")
    }
}

#[derive(Clone)]
pub struct Reply {
    pub status: u16,
    pub content_type: &'static str,
    /// Written as separate writes, to split lines across reads.
    pub chunks: Vec<String>,
}

impl Reply {
    pub fn ok(content_type: &'static str, chunks: Vec<String>) -> Self {
        Self {
            status: 200,
            content_type,
            chunks,
        }
    }
}

pub struct MockServer {
    pub base_url: String,
    pub requests: Arc<Mutex<Vec<Recorded>>>,
}

/// Serves `replies` in order, one per connection.
pub async fn serve(replies: Vec<Reply>) -> MockServer {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let base_url = format!("http://{}", listener.local_addr().expect("addr"));
    let requests = Arc::new(Mutex::new(Vec::new()));
    let recorded = requests.clone();
    tokio::spawn(async move {
        for reply in replies {
            let Ok((mut socket, _)) = listener.accept().await else {
                return;
            };
            let mut data = Vec::new();
            let mut buf = [0u8; 4096];
            let header_end = loop {
                let n = socket.read(&mut buf).await.unwrap_or(0);
                if n == 0 {
                    break None;
                }
                data.extend_from_slice(&buf[..n]);
                if let Some(i) = data.windows(4).position(|w| w == b"\r\n\r\n") {
                    break Some(i);
                }
            };
            let Some(header_end) = header_end else {
                continue;
            };
            let head = String::from_utf8_lossy(&data[..header_end]).into_owned();
            let mut lines = head.split("\r\n");
            let request_line = lines.next().unwrap_or_default().to_string();
            let headers: Vec<(String, String)> = lines
                .filter_map(|l| l.split_once(':'))
                .map(|(k, v)| (k.trim().to_lowercase(), v.trim().to_string()))
                .collect();
            let length: usize = headers
                .iter()
                .find(|(k, _)| k == "content-length")
                .and_then(|(_, v)| v.parse().ok())
                .unwrap_or(0);
            let mut body = data[header_end + 4..].to_vec();
            while body.len() < length {
                let n = socket.read(&mut buf).await.unwrap_or(0);
                if n == 0 {
                    break;
                }
                body.extend_from_slice(&buf[..n]);
            }
            let mut parts = request_line.split(' ');
            recorded.lock().expect("lock").push(Recorded {
                method: parts.next().unwrap_or_default().to_string(),
                path: parts.next().unwrap_or_default().to_string(),
                headers,
                body,
            });

            let total: usize = reply.chunks.iter().map(String::len).sum();
            let head = format!(
                "HTTP/1.1 {} X\r\ncontent-type: {}\r\ncontent-length: {total}\r\nconnection: close\r\n\r\n",
                reply.status, reply.content_type
            );
            let _ = socket.write_all(head.as_bytes()).await;
            for chunk in &reply.chunks {
                let _ = socket.write_all(chunk.as_bytes()).await;
                let _ = socket.flush().await;
                tokio::task::yield_now().await;
            }
            let _ = socket.shutdown().await;
        }
    });
    MockServer { base_url, requests }
}

/// A local port with nothing listening.
pub async fn closed_port_url() -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let url = format!("http://{}", listener.local_addr().expect("addr"));
    drop(listener);
    url
}
