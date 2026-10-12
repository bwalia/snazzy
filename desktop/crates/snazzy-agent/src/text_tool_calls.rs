//! Some local models (e.g. Qwen3-Coder through Ollama) write a tool call into
//! their reply as text instead of returning it as a tool call. This finds those
//! calls so they still run, and removes them from the text.
//!
//! Understood forms:
//! - `<tool_call><function=NAME><parameter=KEY>VALUE</parameter></function></tool_call>`
//! - `<tool_call>{"name": "NAME", "arguments": {...}}</tool_call>`
//! - `<function=NAME>…</function>` (without the outer tool_call tags)

use std::sync::LazyLock;

use regex::Regex;
use serde_json::{Map, Value};

static FUNCTION: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?s)<function=([A-Za-z0-9_\-]+)>(.*?)</function>").expect("regex")
});
static PARAMETER: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?s)<parameter=([A-Za-z0-9_\-]+)>(.*?)</parameter>").expect("regex")
});
static JSON_CALL: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?s)<tool_call>\s*(\{.*?\})\s*</tool_call>").expect("regex"));
static CLEANUP: LazyLock<[Regex; 3]> = LazyLock::new(|| {
    [
        Regex::new(r"(?s)<tool_call>.*?</tool_call>").expect("regex"),
        Regex::new(r"(?s)<function=.*?</function>").expect("regex"),
        Regex::new(r"</?tool_call>").expect("regex"),
    ]
});
static TAG: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"</?tool_call>").expect("regex"));

/// A call found in the text.
#[derive(Debug, Clone, PartialEq)]
pub struct TextCall {
    pub name: String,
    pub arguments: Value,
}

/// The text without the call markup, and the calls; `None` when there are none.
pub fn extract(text: &str) -> Option<(String, Vec<TextCall>)> {
    if !text.contains("<function=") && !text.contains("<tool_call>") {
        return None;
    }
    let mut calls = Vec::new();

    // XML style: <function=NAME> … </function>
    for m in FUNCTION.captures_iter(text) {
        let mut args = Map::new();
        for p in PARAMETER.captures_iter(&m[2]) {
            let raw = p[2].trim_matches(is_newline);
            args.insert(p[1].to_string(), value(raw));
        }
        calls.push(TextCall {
            name: m[1].to_string(),
            arguments: Value::Object(args),
        });
    }

    // JSON style inside <tool_call> … </tool_call>
    if calls.is_empty() {
        for m in JSON_CALL.captures_iter(text) {
            let Ok(json) = serde_json::from_str::<Value>(&m[1]) else {
                continue;
            };
            let Some(name) = json.get("name").and_then(Value::as_str) else {
                continue;
            };
            let mut args = json
                .get("arguments")
                .or_else(|| json.get("parameters"))
                .cloned()
                .unwrap_or_else(|| Value::Object(Map::new()));
            if let Some(parsed) = args.as_str().and_then(|s| serde_json::from_str(s).ok()) {
                args = parsed;
            }
            calls.push(TextCall {
                name: name.to_string(),
                arguments: args,
            });
        }
    }
    if calls.is_empty() {
        return None;
    }

    // Remove the call markup (and empty tool_call wrappers) from the visible text.
    let mut cleaned = text.to_string();
    for re in CLEANUP.iter() {
        cleaned = re.replace_all(&cleaned, "").into_owned();
    }
    Some((cleaned.trim().to_string(), calls))
}

/// A reply with a tool-call tag but no usable call (the model started one and
/// stopped): drops the tags and anything unfinished after an opening one.
pub fn without_stray_markup(text: &str) -> String {
    if !text.contains("<tool_call>")
        && !text.contains("</tool_call>")
        && !text.contains("<function=")
    {
        return text.to_string();
    }
    let mut t = text.to_string();
    for (open_tag, close_tag) in [
        ("<tool_call>", "</tool_call>"),
        ("<function=", "</function>"),
    ] {
        if let Some(open) = t.rfind(open_tag) {
            if !t[open + open_tag.len()..].contains(close_tag) {
                t.truncate(open);
            }
        }
    }
    TAG.replace_all(&t, "").trim().to_string()
}

fn is_newline(c: char) -> bool {
    matches!(
        c,
        '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}'
    )
}

/// Parameter text to JSON (numbers, booleans, arrays and objects stay typed).
fn value(raw: &str) -> Value {
    let t = raw.trim();
    let typed = t
        .chars()
        .next()
        .is_some_and(|c| "[{\"-0123456789tfn".contains(c));
    typed
        .then(|| serde_json::from_str(t).ok())
        .flatten()
        .unwrap_or_else(|| Value::String(raw.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::json::json_eq;
    use serde_json::json;

    #[test]
    fn stray_tags_are_dropped() {
        assert_eq!(
            without_stray_markup("I'll summarise it in one sentence.<tool_call>"),
            "I'll summarise it in one sentence."
        );
        assert_eq!(
            without_stray_markup("Sure.\n<tool_call>\n<function=show_slide"),
            "Sure."
        );
        assert_eq!(without_stray_markup("Plain answer"), "Plain answer");
    }

    #[test]
    fn qwen_xml_style() {
        let text = "I'll create the deck. Let me check the devices first.\n<function=list_devices>\n</function>\n</tool_call>";
        let (text, calls) = extract(text).expect("calls");
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].name, "list_devices");
        assert_eq!(
            text,
            "I'll create the deck. Let me check the devices first."
        );

        let two = "<tool_call>\n<function=write_file>\n<parameter=path>\nindex.html\n</parameter>\n<parameter=content>\n<h1>Hi</h1>\n</parameter>\n</function>\n</tool_call>\n<tool_call><function=show_slide><parameter=index>2</parameter></function></tool_call>";
        let (text, calls) = extract(two).expect("calls");
        let names: Vec<&str> = calls.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(names, ["write_file", "show_slide"]);
        assert_eq!(calls[0].arguments["path"], "index.html");
        assert_eq!(calls[0].arguments["content"], "<h1>Hi</h1>");
        assert!(json_eq(&calls[1].arguments["index"], &json!(2.0)));
        assert!(text.is_empty());
    }

    #[test]
    fn json_style_and_plain_text() {
        let (_, calls) =
            extract(r#"<tool_call>{"name": "next_slide", "arguments": {}}</tool_call>"#)
                .expect("calls");
        assert_eq!(calls[0].name, "next_slide");
        assert_eq!(extract("Just a normal answer about <b>HTML</b>."), None);
    }
}
