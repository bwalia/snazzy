//! Saved chats (Swift `Conversation` and `ConversationStore`): one JSON file
//! per conversation, named `<UUID>.json`, in the format the Mac app writes.

use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;
use uuid::Uuid;

use crate::types::{ChatMessage, uuid_upper};

/// Swift `JSONEncoder.dateEncodingStrategy = .iso8601`: whole seconds, UTC, `Z`.
mod iso8601 {
    use super::*;

    pub fn serialize<S: Serializer>(date: &OffsetDateTime, s: S) -> Result<S::Ok, S::Error> {
        let utc = date
            .to_offset(time::UtcOffset::UTC)
            .replace_nanosecond(0)
            .map_err(serde::ser::Error::custom)?;
        s.serialize_str(&utc.format(&Rfc3339).map_err(serde::ser::Error::custom)?)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<OffsetDateTime, D::Error> {
        let text = String::deserialize(d)?;
        OffsetDateTime::parse(&text, &Rfc3339).map_err(serde::de::Error::custom)
    }
}

fn now() -> OffsetDateTime {
    OffsetDateTime::now_utc()
        .replace_nanosecond(0)
        .unwrap_or(OffsetDateTime::UNIX_EPOCH)
}

/// A saved chat: the provider-neutral history plus a title.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Conversation {
    #[serde(with = "uuid_upper")]
    pub id: Uuid,
    pub title: String,
    #[serde(with = "iso8601")]
    pub created: OffsetDateTime,
    #[serde(with = "iso8601")]
    pub updated: OffsetDateTime,
    #[serde(default)]
    pub messages: Vec<ChatMessage>,
    /// Tokens used across the conversation.
    #[serde(rename = "inputTokens", default)]
    pub input_tokens: i64,
    #[serde(rename = "outputTokens", default)]
    pub output_tokens: i64,
    /// The settings preset last loaded in this conversation, if any.
    #[serde(
        rename = "presetName",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub preset_name: Option<String>,
}

impl Default for Conversation {
    fn default() -> Self {
        Self::new("New conversation", Vec::new())
    }
}

impl Conversation {
    pub fn new(title: impl Into<String>, messages: Vec<ChatMessage>) -> Self {
        let created = now();
        Self {
            id: Uuid::new_v4(),
            title: title.into(),
            created,
            updated: created,
            messages,
            input_tokens: 0,
            output_tokens: 0,
            preset_name: None,
        }
    }

    /// A title from the first user message.
    pub fn title_from(text: &str) -> String {
        let line = text
            .split(is_newline)
            .find(|l| !l.is_empty())
            .unwrap_or(text);
        let trimmed = line.trim_matches(|c: char| c.is_whitespace() && !is_newline(c));
        if trimmed.is_empty() {
            return "New conversation".into();
        }
        if trimmed.chars().count() > 60 {
            format!("{}…", trimmed.chars().take(57).collect::<String>())
        } else {
            trimmed.to_string()
        }
    }

    /// History up to (not including) the message with this ID; used to edit or
    /// retry a turn. Earlier turns are kept unchanged.
    pub fn truncated(&self, before: Uuid) -> Vec<ChatMessage> {
        match self.messages.iter().position(|m| m.id == before) {
            Some(i) => self.messages[..i].to_vec(),
            None => self.messages.clone(),
        }
    }
}

fn is_newline(c: char) -> bool {
    matches!(
        c,
        '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}'
    )
}

#[derive(Debug, Clone, PartialEq)]
pub struct ConversationSummary {
    pub id: Uuid,
    pub title: String,
    pub updated: OffsetDateTime,
}

/// One JSON file per conversation in a directory (chosen by the caller).
#[derive(Debug, Clone)]
pub struct ConversationStore {
    pub directory: PathBuf,
}

impl ConversationStore {
    pub fn new(directory: impl Into<PathBuf>) -> Self {
        Self {
            directory: directory.into(),
        }
    }

    fn path(&self, id: Uuid) -> PathBuf {
        self.directory.join(format!(
            "{}.json",
            id.hyphenated().to_string().to_uppercase()
        ))
    }

    /// Writes atomically (a temporary sibling, then a rename).
    pub fn save(&self, conversation: &Conversation) -> io::Result<()> {
        std::fs::create_dir_all(&self.directory)?;
        let data = serde_json::to_vec(conversation).map_err(io::Error::other)?;
        let path = self.path(conversation.id);
        let temp = path.with_extension("json.partial");
        std::fs::write(&temp, data)?;
        std::fs::rename(&temp, &path)
    }

    pub fn load(&self, id: Uuid) -> io::Result<Conversation> {
        read(&self.path(id))
    }

    pub fn delete(&self, id: Uuid) {
        let _ = std::fs::remove_file(self.path(id));
    }

    /// Newest first. Unreadable files are skipped.
    pub fn list(&self) -> Vec<ConversationSummary> {
        let Ok(entries) = std::fs::read_dir(&self.directory) else {
            return Vec::new();
        };
        let mut out: Vec<ConversationSummary> = entries
            .filter_map(Result::ok)
            .map(|e| e.path())
            .filter(|p| p.extension().is_some_and(|x| x == "json"))
            .filter_map(|p| read(&p).ok())
            .map(|c| ConversationSummary {
                id: c.id,
                title: c.title,
                updated: c.updated,
            })
            .collect();
        out.sort_by_key(|s| std::cmp::Reverse(s.updated));
        out
    }
}

fn read(path: &Path) -> io::Result<Conversation> {
    let data = std::fs::read(path)?;
    serde_json::from_slice(&data).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{ChatRole, ContentPart, ProviderKind, ToolCall, ToolResult};
    use serde_json::json;

    fn sample() -> Conversation {
        Conversation::new(
            "First",
            vec![
                ChatMessage::user("hello"),
                ChatMessage::new(
                    ChatRole::Assistant,
                    vec![
                        ContentPart::Opaque {
                            provider: ProviderKind::Anthropic,
                            block: json!({"type": "thinking", "thinking": "x", "signature": "s"}),
                        },
                        ContentPart::Text("hi".into()),
                        ContentPart::ToolCall(ToolCall::new("t1", "list_devices", json!({}))),
                    ],
                ),
                ChatMessage::new(
                    ChatRole::Tool,
                    vec![ContentPart::ToolResult(ToolResult::new(
                        "t1",
                        "list_devices",
                        "{}",
                    ))],
                ),
                ChatMessage::new(
                    ChatRole::User,
                    vec![
                        ContentPart::Image {
                            media_type: "image/png".into(),
                            data: vec![1, 2, 3],
                        },
                        ContentPart::Text("look".into()),
                    ],
                ),
            ],
        )
    }

    #[test]
    fn store_round_trip_and_listing() {
        let dir = tempfile::tempdir().expect("tempdir");
        let store = ConversationStore::new(dir.path().join("Conversations"));
        assert!(store.list().is_empty());

        let mut a = sample();
        a.updated = OffsetDateTime::from_unix_timestamp(1000).expect("date");
        let mut b = Conversation::new("Second", Vec::new());
        b.updated = OffsetDateTime::from_unix_timestamp(2000).expect("date");
        store.save(&a).expect("save a");
        store.save(&b).expect("save b");

        let loaded = store.load(a.id).expect("load");
        assert_eq!(loaded.messages, a.messages);
        let titles: Vec<String> = store.list().into_iter().map(|s| s.title).collect();
        assert_eq!(titles, ["Second", "First"]);
        store.delete(b.id);
        let titles: Vec<String> = store.list().into_iter().map(|s| s.title).collect();
        assert_eq!(titles, ["First"]);
    }

    #[test]
    fn titles_and_truncation() {
        assert_eq!(
            Conversation::title_from("  Make a deck\nwith details"),
            "Make a deck"
        );
        assert_eq!(
            Conversation::title_from(&"a".repeat(80)).chars().count(),
            58
        );
        assert_eq!(Conversation::title_from("\n\n  "), "New conversation");
        let first = ChatMessage::user("one");
        let second = ChatMessage::user("two");
        let c = Conversation::new(
            "t",
            vec![
                first.clone(),
                ChatMessage::new(ChatRole::Assistant, vec![ContentPart::Text("ok".into())]),
                second.clone(),
            ],
        );
        assert_eq!(c.truncated(second.id).len(), 2);
        assert!(c.truncated(first.id).is_empty());
    }

    /// The exact JSON Swift's `Codable` writes for a conversation.
    #[test]
    fn reads_and_writes_the_swift_format() {
        let swift = r#"{
          "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
          "title": "Deck",
          "created": "2026-10-13T09:00:00Z",
          "updated": "2026-10-13T09:05:00Z",
          "inputTokens": 120,
          "outputTokens": 42,
          "messages": [
            {"id": "11111111-2222-3333-4444-555555555555", "role": "user",
             "parts": [{"text": {"_0": "hi"}}, {"image": {"mediaType": "image/png", "data": "AQID"}}]},
            {"id": "21111111-2222-3333-4444-555555555555", "role": "assistant",
             "parts": [
               {"opaque": {"provider": "anthropic", "block": {"type": "thinking", "thinking": "hm", "signature": "c2ln/+=="}}},
               {"toolCall": {"_0": {"id": "toolu_1", "name": "set_inset", "arguments": {"position": "topLeft"}}}}
             ]},
            {"id": "31111111-2222-3333-4444-555555555555", "role": "tool",
             "parts": [{"toolResult": {"_0": {"callID": "toolu_1", "name": "set_inset", "content": "{}", "isError": false}}}]}
          ]
        }"#;
        let c: Conversation = serde_json::from_str(swift).expect("decode");
        assert_eq!(c.title, "Deck");
        assert_eq!(c.input_tokens, 120);
        assert_eq!(c.preset_name, None);
        assert_eq!(
            c.messages[0].parts[1],
            ContentPart::Image {
                media_type: "image/png".into(),
                data: vec![1, 2, 3]
            }
        );
        assert_eq!(
            c.messages[1].parts[0],
            ContentPart::Opaque {
                provider: ProviderKind::Anthropic,
                block: json!({"type": "thinking", "thinking": "hm", "signature": "c2ln/+=="}),
            }
        );
        assert_eq!(c.messages[2].role, ChatRole::Tool);

        let written = serde_json::to_value(&c).expect("encode");
        let original: serde_json::Value = serde_json::from_str(swift).expect("json");
        assert_eq!(written, original);
    }
}
