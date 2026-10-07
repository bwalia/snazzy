import Foundation
import SnazzyCore

/// Validates tool arguments against the JSON Schema subset our tools use:
/// type, enum, properties, required, additionalProperties, items, numeric and
/// length bounds. Local models often get tool calls wrong, so every call is
/// checked before it runs.
public enum SchemaValidator {
    public static func validate(_ value: JSONValue, against schema: JSONValue, path: String = "$") -> [String] {
        var errors: [String] = []

        if let types = allowedTypes(schema), !types.contains(where: { matches(value, type: $0) }) {
            errors.append("\(path): expected \(types.joined(separator: " or ")), got \(value.schemaTypeName)")
            return errors
        }

        if let options = schema["enum"]?.arrayValue, !options.contains(value) {
            let list = options.map(\.compactString).joined(separator: ", ")
            errors.append("\(path): must be one of [\(list)], got \(value.compactString)")
        }

        switch value {
        case .object(let object):
            let properties = schema["properties"]?.objectValue ?? [:]
            for name in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where object[name] == nil {
                errors.append("\(path): missing required property '\(name)'")
            }
            for (key, child) in object.sorted(by: { $0.key < $1.key }) {
                if let childSchema = properties[key] {
                    errors += validate(child, against: childSchema, path: "\(path).\(key)")
                } else if schema["additionalProperties"] == .bool(false) {
                    errors.append("\(path): unexpected property '\(key)'")
                }
            }
        case .array(let items):
            if let min = schema["minItems"]?.intValue, items.count < min {
                errors.append("\(path): needs at least \(min) items")
            }
            if let max = schema["maxItems"]?.intValue, items.count > max {
                errors.append("\(path): allows at most \(max) items")
            }
            if let itemSchema = schema["items"] {
                for (i, item) in items.enumerated() {
                    errors += validate(item, against: itemSchema, path: "\(path)[\(i)]")
                }
            }
        case .number(let n):
            if let min = schema["minimum"]?.doubleValue, n < min { errors.append("\(path): must be ≥ \(min.clean)") }
            if let max = schema["maximum"]?.doubleValue, n > max { errors.append("\(path): must be ≤ \(max.clean)") }
        case .string(let s):
            if let min = schema["minLength"]?.intValue, s.count < min {
                errors.append("\(path): must be at least \(min) characters")
            }
            if let max = schema["maxLength"]?.intValue, s.count > max {
                errors.append("\(path): must be at most \(max) characters")
            }
        default:
            break
        }
        return errors
    }

    private static func allowedTypes(_ schema: JSONValue) -> [String]? {
        switch schema["type"] {
        case .string(let t)?: [t]
        case .array(let ts)?: ts.compactMap(\.stringValue)
        default: nil
        }
    }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("null", .null), ("boolean", .bool), ("string", .string), ("array", .array), ("object", .object),
            ("number", .number):
            true
        case ("integer", .number(let n)): n.rounded() == n
        default: false
        }
    }
}

private extension Double {
    var clean: String { rounded() == self ? String(Int(self)) : String(self) }
}
