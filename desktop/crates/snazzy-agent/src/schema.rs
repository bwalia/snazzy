//! Validates tool arguments against the JSON Schema subset the tools use:
//! `type`, `enum`, `properties`, `required`, `additionalProperties`, `items`,
//! `minItems`/`maxItems`, `minimum`/`maximum`, `minLength`/`maxLength`.
//! Local models often get tool calls wrong, so every call is checked first.

use serde_json::Value;

use crate::json::{compact_string, int_value, is_integral, json_eq, schema_type_name};

/// Every problem found; empty means valid. `path` starts at `"$"`.
pub fn validate(value: &Value, schema: &Value) -> Vec<String> {
    validate_at(value, schema, "$")
}

fn validate_at(value: &Value, schema: &Value, path: &str) -> Vec<String> {
    let mut errors = Vec::new();

    if let Some(types) = allowed_types(schema) {
        if !types.iter().any(|t| matches(value, t)) {
            errors.push(format!(
                "{path}: expected {}, got {}",
                types.join(" or "),
                schema_type_name(value)
            ));
            return errors;
        }
    }

    if let Some(options) = schema.get("enum").and_then(Value::as_array) {
        if !options.iter().any(|o| json_eq(o, value)) {
            let list: Vec<String> = options.iter().map(compact_string).collect();
            errors.push(format!(
                "{path}: must be one of [{}], got {}",
                list.join(", "),
                compact_string(value)
            ));
        }
    }

    match value {
        Value::Object(object) => {
            let properties = schema.get("properties").and_then(Value::as_object);
            for name in schema
                .get("required")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
            {
                if !object.contains_key(name) {
                    errors.push(format!("{path}: missing required property '{name}'"));
                }
            }
            let mut keys: Vec<&String> = object.keys().collect();
            keys.sort();
            for key in keys {
                if let Some(child_schema) = properties.and_then(|p| p.get(key)) {
                    errors.extend(validate_at(
                        &object[key],
                        child_schema,
                        &format!("{path}.{key}"),
                    ));
                } else if schema.get("additionalProperties") == Some(&Value::Bool(false)) {
                    errors.push(format!("{path}: unexpected property '{key}'"));
                }
            }
        }
        Value::Array(items) => {
            let count = items.len() as i64;
            if let Some(min) = schema.get("minItems").and_then(int_value) {
                if count < min {
                    errors.push(format!("{path}: needs at least {min} items"));
                }
            }
            if let Some(max) = schema.get("maxItems").and_then(int_value) {
                if count > max {
                    errors.push(format!("{path}: allows at most {max} items"));
                }
            }
            if let Some(item_schema) = schema.get("items") {
                for (i, item) in items.iter().enumerate() {
                    errors.extend(validate_at(item, item_schema, &format!("{path}[{i}]")));
                }
            }
        }
        Value::Number(n) => {
            let n = n.as_f64().unwrap_or(0.0);
            if let Some(min) = schema.get("minimum").and_then(Value::as_f64) {
                if n < min {
                    errors.push(format!("{path}: must be ≥ {}", clean(min)));
                }
            }
            if let Some(max) = schema.get("maximum").and_then(Value::as_f64) {
                if n > max {
                    errors.push(format!("{path}: must be ≤ {}", clean(max)));
                }
            }
        }
        Value::String(s) => {
            let count = s.chars().count() as i64;
            if let Some(min) = schema.get("minLength").and_then(int_value) {
                if count < min {
                    errors.push(format!("{path}: must be at least {min} characters"));
                }
            }
            if let Some(max) = schema.get("maxLength").and_then(int_value) {
                if count > max {
                    errors.push(format!("{path}: must be at most {max} characters"));
                }
            }
        }
        _ => {}
    }
    errors
}

fn allowed_types(schema: &Value) -> Option<Vec<&str>> {
    match schema.get("type")? {
        Value::String(t) => Some(vec![t.as_str()]),
        Value::Array(ts) => Some(ts.iter().filter_map(Value::as_str).collect()),
        _ => None,
    }
}

fn matches(value: &Value, kind: &str) -> bool {
    match (kind, value) {
        ("null", Value::Null)
        | ("boolean", Value::Bool(_))
        | ("string", Value::String(_))
        | ("array", Value::Array(_))
        | ("object", Value::Object(_))
        | ("number", Value::Number(_)) => true,
        ("integer", Value::Number(n)) => is_integral(n),
        _ => false,
    }
}

fn clean(n: f64) -> String {
    if n.round() == n && n.abs() < 9.0e15 {
        format!("{}", n as i64)
    } else {
        format!("{n}")
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use serde_json::json;

    pub fn inset_schema() -> Value {
        json!({
            "type": "object",
            "properties": {
                "position": {"type": "string", "enum": ["topLeft", "topRight", "bottomLeft", "bottomRight"]},
                "size": {"type": "number", "minimum": 0.05, "maximum": 0.6},
                "corners": {"type": "integer"},
                "tags": {"type": "array", "items": {"type": "string"}, "maxItems": 2},
            },
            "required": ["position"],
            "additionalProperties": false,
        })
    }

    #[test]
    fn accepts_valid() {
        assert!(
            validate(
                &json!({"position": "bottomRight", "size": 0.25, "corners": 12}),
                &inset_schema()
            )
            .is_empty()
        );
    }

    #[test]
    fn reports_every_problem() {
        let errors = validate(
            &json!({"size": 2, "corners": 1.5, "extra": true, "tags": ["a", 1, "c"]}),
            &inset_schema(),
        );
        for expected in [
            "$: missing required property 'position'",
            "$.size: must be ≤ 0.6",
            "$.corners: expected integer, got number",
            "$: unexpected property 'extra'",
            "$.tags: allows at most 2 items",
            "$.tags[1]: expected string, got integer",
        ] {
            assert!(
                errors.iter().any(|e| e == expected),
                "missing {expected:?} in {errors:?}"
            );
        }
    }

    #[test]
    fn enum_and_top_level_type() {
        assert_eq!(
            validate(&json!({"position": "middle"}), &inset_schema()),
            [
                r#"$.position: must be one of ["topLeft", "topRight", "bottomLeft", "bottomRight"], got "middle""#
            ]
        );
        assert_eq!(
            validate(&json!("{\"position\":"), &inset_schema()),
            ["$: expected object, got string"]
        );
    }

    #[test]
    fn lengths_items_and_integral_floats() {
        let schema = json!({"type": "object", "properties": {
            "name": {"type": "string", "minLength": 2, "maxLength": 3},
            "list": {"type": "array", "minItems": 1},
            "n": {"type": ["integer", "null"], "minimum": 1},
        }});
        assert_eq!(
            validate(&json!({"name": "a", "list": [], "n": 0.0}), &schema),
            [
                "$.list: needs at least 1 items",
                "$.n: must be ≥ 1",
                "$.name: must be at least 2 characters",
            ]
        );
        assert_eq!(
            validate(&json!({"name": "abcd"}), &schema),
            ["$.name: must be at most 3 characters"]
        );
        assert!(validate(&json!({"n": 2.0}), &schema).is_empty());
        assert!(validate(&json!({"n": null}), &schema).is_empty());
        // Enum values compare as numbers, like Swift's JSONValue.
        assert!(validate(&json!(1.0), &json!({"enum": [1, 2]})).is_empty());
    }
}
