//! JSON written byte for byte as Swift's `JSONEncoder` writes it with
//! `.sortedKeys` (see docs/specs/README.md):
//!
//! - keys sorted by their UTF-8 bytes;
//! - pretty printing as `"key" : value` with two-space indents, and empty
//!   containers as `[`, a blank line, then `]`;
//! - `/` escaped as `\/` unless `.withoutEscapingSlashes`;
//! - `\b \f \n \r \t`, other control characters as `\u00xx`, everything else raw;
//! - doubles: integral values up to 2^53 without a fraction, otherwise the
//!   shortest round-trip digits, with an exponent (`1e+16`, `1e-05`) outside
//!   1e-4 ..< 1e16.
//!
//! Values go through `serde_json::Value` (whose map is sorted), so the struct
//! field order doesn't matter.

use serde::Serialize;
use serde_json::{Number, Value};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Style {
    pub pretty: bool,
    pub escape_slashes: bool,
}

impl Style {
    /// `JSONEncoder` with `[.sortedKeys]` (.snazzy contents, remote frames).
    pub const COMPACT: Style = Style {
        pretty: false,
        escape_slashes: true,
    };
    /// `[.prettyPrinted, .sortedKeys]` (deck.json, .snazzy-project.json, presets).
    pub const PRETTY: Style = Style {
        pretty: true,
        escape_slashes: true,
    };
    /// `JSONValue.encoded()`: `[.sortedKeys, .withoutEscapingSlashes]` (timeline.json).
    pub const COMPACT_UNESCAPED: Style = Style {
        pretty: false,
        escape_slashes: false,
    };
    /// `[.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]`.
    pub const PRETTY_UNESCAPED: Style = Style {
        pretty: true,
        escape_slashes: false,
    };
}

/// Encodes `value` as Swift would. Fails only if serde can't represent it as JSON.
pub fn to_string<T: Serialize + ?Sized>(value: &T, style: Style) -> serde_json::Result<String> {
    Ok(write_value(&serde_json::to_value(value)?, style))
}

pub fn to_vec<T: Serialize + ?Sized>(value: &T, style: Style) -> serde_json::Result<Vec<u8>> {
    to_string(value, style).map(String::into_bytes)
}

pub fn write_value(value: &Value, style: Style) -> String {
    let mut out = String::new();
    write(&mut out, value, style, 0);
    out
}

fn indent(out: &mut String, level: usize) {
    for _ in 0..level {
        out.push_str("  ");
    }
}

fn write(out: &mut String, value: &Value, style: Style, level: usize) {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Value::Number(n) => out.push_str(&number(n)),
        Value::String(s) => string(out, s, style.escape_slashes),
        Value::Array(items) => {
            out.push('[');
            if style.pretty {
                out.push('\n');
                if items.is_empty() {
                    out.push('\n');
                }
                for (i, item) in items.iter().enumerate() {
                    indent(out, level + 1);
                    write(out, item, style, level + 1);
                    out.push_str(if i + 1 < items.len() { ",\n" } else { "\n" });
                }
                indent(out, level);
            } else {
                for (i, item) in items.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    write(out, item, style, level);
                }
            }
            out.push(']');
        }
        Value::Object(map) => {
            // serde_json's map is a BTreeMap<String, _>: already in byte order.
            out.push('{');
            if style.pretty {
                out.push('\n');
                if map.is_empty() {
                    out.push('\n');
                }
                for (i, (k, v)) in map.iter().enumerate() {
                    indent(out, level + 1);
                    string(out, k, style.escape_slashes);
                    out.push_str(" : ");
                    write(out, v, style, level + 1);
                    out.push_str(if i + 1 < map.len() { ",\n" } else { "\n" });
                }
                indent(out, level);
            } else {
                for (i, (k, v)) in map.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    string(out, k, style.escape_slashes);
                    out.push(':');
                    write(out, v, style, level);
                }
            }
            out.push('}');
        }
    }
}

fn string(out: &mut String, s: &str, escape_slashes: bool) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '/' if escape_slashes => out.push_str("\\/"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

fn number(n: &Number) -> String {
    if let Some(f) = n.as_f64().filter(|_| n.is_f64()) {
        double(f)
    } else {
        n.to_string()
    }
}

/// A double as Swift's JSONEncoder writes it.
pub fn double(f: f64) -> String {
    if !f.is_finite() {
        // JSONEncoder refuses these; serde_json turns them into null before we get here.
        return "null".into();
    }
    if f.fract() == 0.0 && f.abs() <= 9_007_199_254_740_992.0 {
        return format!("{f}");
    }
    // Shortest round-trip digits, e.g. "1.2345678901234567e19" or "5e-324".
    let sci = format!("{f:e}");
    let (mantissa, exp) = sci.split_once('e').unwrap_or((&sci, "0"));
    let exp: i32 = exp.parse().unwrap_or(0);
    if (-4..16).contains(&exp) {
        format!("{f}")
    } else {
        format!(
            "{mantissa}e{}{:02}",
            if exp < 0 { '-' } else { '+' },
            exp.abs()
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn doubles_match_swift() {
        // From Swift: [1e15, 123456789012345.0, 1e16, 2.5e-4, 1e-4, 0.001, 5e-324, -0.0, 1234567.125,
        // 9007199254740992, 1.7976931348623157e308, 0.1 + 0.2, 100, 1e21, 12345678901234567890.0, 0.000123, 0.00001]
        let cases = [
            (1e15, "1000000000000000"),
            (123_456_789_012_345.0, "123456789012345"),
            (1e16, "1e+16"),
            (2.5e-4, "0.00025"),
            (1e-4, "0.0001"),
            (0.001, "0.001"),
            (5e-324, "5e-324"),
            (-0.0, "-0"),
            (1_234_567.125, "1234567.125"),
            (9_007_199_254_740_992.0, "9007199254740992"),
            (f64::MAX, "1.7976931348623157e+308"),
            (0.1 + 0.2, "0.30000000000000004"),
            (100.0, "100"),
            (1e21, "1e+21"),
            (12_345_678_901_234_567_890.0, "1.2345678901234567e+19"),
            (0.000123, "0.000123"),
            (0.00001, "1e-05"),
        ];
        for (f, s) in cases {
            assert_eq!(double(f), s, "{f}");
        }
    }

    #[test]
    fn strings_and_layout_match_swift() {
        let v = json!({"s": "\u{8}\u{c}\u{1f}\u{7f}\u{85}\u{2028}\"\\/é😀", "B": 2, "é": 3, "e": [], "o": {}, "n": {"k": [1, 2]}});
        assert_eq!(
            write_value(&v, Style::COMPACT),
            "{\"B\":2,\"e\":[],\"n\":{\"k\":[1,2]},\"o\":{},\"s\":\"\\b\\f\\u001f\u{7f}\u{85}\u{2028}\\\"\\\\\\/é😀\",\"é\":3}"
        );
        assert_eq!(
            write_value(
                &json!({"e": [], "n": {"k": [1, 2]}, "o": {}}),
                Style::PRETTY
            ),
            "{\n  \"e\" : [\n\n  ],\n  \"n\" : {\n    \"k\" : [\n      1,\n      2\n    ]\n  },\n  \"o\" : {\n\n  }\n}"
        );
    }
}
