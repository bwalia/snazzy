//! The `ModelProvider` trait and the HTTP plumbing the providers share.

use std::future::Future;

use futures_util::future::{self, BoxFuture};
use futures_util::stream::{self, BoxStream, StreamExt};
use serde_json::Value;
use tokio::sync::mpsc;

use crate::types::{ModelInfo, ModelRequest, ProviderError, ProviderKind, StreamEvent};

/// The events of one model turn. Dropping the stream cancels the request.
pub type EventStream = BoxStream<'static, Result<StreamEvent, ProviderError>>;

/// A chat model backend with streaming and tool calling.
///
/// `stream` yields deltas and ends with exactly one
/// [`StreamEvent::Completed`], or an error.
pub trait ModelProvider: Send + Sync {
    fn kind(&self) -> ProviderKind;
    fn list_models(&self) -> BoxFuture<'_, Result<Vec<ModelInfo>, ProviderError>>;
    fn stream(&self, request: ModelRequest) -> EventStream;
}

/// Sends items to a stream made by [`channel_stream`].
pub(crate) struct Emitter<T>(mpsc::UnboundedSender<T>);

impl<T> Emitter<T> {
    pub fn emit(&self, item: T) {
        // The receiver is gone only when the stream was dropped; the driver
        // future is dropped with it, so nothing is lost.
        let _ = self.0.send(item);
    }
}

impl<T> Clone for Emitter<T> {
    fn clone(&self) -> Self {
        Self(self.0.clone())
    }
}

/// A stream fed by an async body. The body runs as the stream is polled (no
/// task is spawned), so dropping the stream cancels it.
pub(crate) fn channel_stream<T, F, Fut>(body: F) -> BoxStream<'static, T>
where
    T: Send + 'static,
    F: FnOnce(Emitter<T>) -> Fut,
    Fut: Future<Output = ()> + Send + 'static,
{
    let (tx, mut rx) = mpsc::unbounded_channel();
    let driver = body(Emitter(tx));
    let items = stream::poll_fn(move |cx| rx.poll_recv(cx));
    let driver = stream::once(driver).filter_map(|()| future::ready(None));
    stream::select(items, driver).boxed()
}

pub(crate) fn validate_base_url(base: &str) -> Result<String, ProviderError> {
    match reqwest::Url::parse(base) {
        Ok(url) if url.has_host() => Ok(base.trim_end_matches('/').to_string()),
        _ => Err(ProviderError::InvalidBaseUrl(base.to_string())),
    }
}

pub(crate) fn host_of(url: &str) -> String {
    reqwest::Url::parse(url)
        .ok()
        .and_then(|u| u.host_str().map(|h| h.trim_matches(['[', ']']).to_string()))
        .unwrap_or_else(|| "server".to_string())
}

/// User-readable text for a failed connection (Swift `HTTP.describe`).
pub(crate) fn describe(error: &reqwest::Error, url: &str) -> String {
    let host = host_of(url);
    if error.is_timeout() {
        format!("{host} timed out.")
    } else if error.is_connect() {
        format!("Cannot connect to {host}. Is it running?")
    } else {
        format!("{host}: {error}")
    }
}

pub(crate) type ErrorMessage = fn(&Value) -> Option<String>;

/// Sends a request; a non-2xx status becomes `ProviderError::Http` with the
/// body's error message.
pub(crate) async fn send(
    request: reqwest::RequestBuilder,
    url: &str,
    error_message: ErrorMessage,
) -> Result<reqwest::Response, ProviderError> {
    let mut response = request
        .send()
        .await
        .map_err(|e| ProviderError::Unreachable(describe(&e, url)))?;
    let status = response.status();
    if status.is_success() {
        return Ok(response);
    }
    let mut body = Vec::new();
    while let Ok(Some(chunk)) = response.chunk().await {
        body.extend_from_slice(&chunk);
        if body.len() > 64_000 {
            break;
        }
    }
    let message = serde_json::from_slice::<Value>(&body)
        .ok()
        .and_then(|json| error_message(&json))
        .unwrap_or_else(|| String::from_utf8_lossy(&body).into_owned());
    Err(ProviderError::Http {
        status: status.as_u16(),
        message,
    })
}

/// A whole JSON response.
pub(crate) async fn data(
    request: reqwest::RequestBuilder,
    url: &str,
    error_message: ErrorMessage,
) -> Result<Value, ProviderError> {
    let response = send(request, url, error_message).await?;
    let bytes = response
        .bytes()
        .await
        .map_err(|e| ProviderError::Unreachable(describe(&e, url)))?;
    serde_json::from_slice(&bytes)
        .map_err(|_| ProviderError::MalformedResponse("invalid JSON".into()))
}

/// Parses a line-oriented stream (SSE or NDJSON) into events.
pub(crate) trait LineParser: Send + 'static {
    fn consume_line(&mut self, line: &str) -> Result<Vec<StreamEvent>, ProviderError>;
    fn is_finished(&self) -> bool;
    fn completion(&self) -> StreamEvent;
}

/// Reads the response line by line through `parser`, then emits its completion.
pub(crate) async fn pump_lines<P: LineParser>(
    mut response: reqwest::Response,
    url: &str,
    mut parser: P,
    emit: &Emitter<Result<StreamEvent, ProviderError>>,
) -> Result<(), ProviderError> {
    let mut buffer: Vec<u8> = Vec::new();
    'read: loop {
        let chunk = response
            .chunk()
            .await
            .map_err(|e| ProviderError::Unreachable(describe(&e, url)))?;
        let Some(chunk) = chunk else { break };
        buffer.extend_from_slice(&chunk);
        while let Some(end) = buffer.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = buffer.drain(..=end).collect();
            for event in parser.consume_line(trim_eol(&line).as_ref())? {
                emit.emit(Ok(event));
            }
            if parser.is_finished() {
                break 'read;
            }
        }
    }
    if !parser.is_finished() && !buffer.is_empty() {
        for event in parser.consume_line(trim_eol(&buffer).as_ref())? {
            emit.emit(Ok(event));
        }
    }
    emit.emit(Ok(parser.completion()));
    Ok(())
}

fn trim_eol(line: &[u8]) -> std::borrow::Cow<'_, str> {
    let mut end = line.len();
    while end > 0 && (line[end - 1] == b'\n' || line[end - 1] == b'\r') {
        end -= 1;
    }
    String::from_utf8_lossy(&line[..end])
}
