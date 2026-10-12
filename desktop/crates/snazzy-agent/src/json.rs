//! Helpers that make `serde_json::Value` behave like the Swift `JSONValue`:
//! every number is a double (so `1` equals `1.0`), integral numbers print
//! without a fraction, and compact output has sorted keys.

use serde_json::{Map, Number, Value};

/// Swift `intValue`: the number truncated toward zero, or `None` when it
/// isn't a number or doesn't fit.
pub fn int_value(value: &Value) -> Option<i64> {
    let n = value.as_f64()?.trunc();
    if n.is_finite() && n >= i64::MIN as f64 && n < i64::MAX as f64 {
        Some(n as i64)
    } else {
        None
    }
}

/// True for numbers without a fractional part (JSON Schema `integer`).
pub fn is_integral(n: &Number) -> bool {
    if n.is_i64() || n.is_u64() {
        return true;
    }
    n.as_f64().is_some_and(|f| f.is_finite() && f.round() == f)
}

/// JSON Schema type name of a value, as the Swift validator reports it.
pub fn schema_type_name(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "boolean",
        Value::Number(n) if is_integral(n) => "integer",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

/// Equality with numbers compared as doubles (Swift `JSONValue ==`).
pub fn json_eq(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => x.as_f64() == y.as_f64(),
        (Value::Array(x), Value::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(a, b)| json_eq(a, b))
        }
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len()
                && x.iter()
                    .all(|(k, v)| y.get(k).is_some_and(|w| json_eq(v, w)))
        }
        _ => a == b,
    }
}

/// Integral doubles below 1e15 become integers, as Swift encodes them.
pub fn normalized(value: &Value) -> Value {
    match value {
        Value::Number(n) if !n.is_i64() && !n.is_u64() => match n.as_f64() {
            Some(f) if f.round() == f && f.abs() < 1e15 => Value::from(f as i64),
            _ => value.clone(),
        },
        Value::Array(items) => Value::Array(items.iter().map(normalized).collect()),
        Value::Object(map) => {
            let mut out = Map::new();
            for (k, v) in map {
                out.insert(k.clone(), normalized(v));
            }
            Value::Object(out)
        }
        _ => value.clone(),
    }
}

/// Compact JSON text with sorted keys (Swift `compactString`), whatever
/// map ordering serde_json was built with.
pub fn compact_string(value: &Value) -> String {
    let mut out = String::new();
    write_sorted(&normalized(value), &mut out);
    out
}

fn write_sorted(value: &Value, out: &mut String) {
    match value {
        Value::Array(items) => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_sorted(item, out);
            }
            out.push(']');
        }
        Value::Object(map) => {
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort();
            out.push('{');
            for (i, key) in keys.into_iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                out.push_str(&Value::String(key.clone()).to_string());
                out.push(':');
                write_sorted(&map[key], out);
            }
            out.push('}');
        }
        other => out.push_str(&other.to_string()),
    }
}

/// Parses JSON text into a value.
pub fn parse(text: &str) -> Option<Value> {
    serde_json::from_str(text).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn numbers_compare_and_print_like_swift() {
        assert!(json_eq(&json!({"a": [1, 2.0]}), &json!({"a": [1.0, 2]})));
        assert_eq!(
            compact_string(&json!({"b": 2.0, "a": 0.6})),
            r#"{"a":0.6,"b":2}"#
        );
        assert_eq!(int_value(&json!(1.9)), Some(1));
        assert_eq!(int_value(&json!(1e300)), None);
        assert_eq!(schema_type_name(&json!(1.0)), "integer");
        assert_eq!(schema_type_name(&json!(1.5)), "number");
    }
}
