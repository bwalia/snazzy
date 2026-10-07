import Foundation
import SnazzyCore

/// Model Context Protocol constants and shared types.
///
/// Snazzy Pro is dual-era: it speaks the modern, stateless protocol
/// (2026-07-28: per-request `_meta`, `server/discover`) and falls back to the
/// legacy `initialize` handshake (2025-03-26 … 2025-11-25) over Streamable HTTP.
public enum MCPProtocol {
    public static let modernVersion = "2026-07-28"
    public static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]
    public static let allVersions = [modernVersion] + legacyVersions

    public static let headerMismatch = -32020
    public static let missingCapability = -32021
    public static let unsupportedVersion = -32022
    public static let methodNotFound = -32601
    public static let invalidParams = -32602

    /// Error codes that only modern servers send (used to detect the server's era).
    public static let modernErrorCodes: Set<Int> = [headerMismatch, missingCapability, unsupportedVersion]

    public static func implementation(_ name: String, _ version: String) -> JSONValue {
        ["name": .string(name), "version": .string(version)]
    }

    /// `_meta` for a modern request.
    public static func requestMeta(clientName: String, clientVersion: String) -> JSONValue {
        [
            "io.modelcontextprotocol/protocolVersion": .string(modernVersion),
            "io.modelcontextprotocol/clientInfo": implementation(clientName, clientVersion),
            "io.modelcontextprotocol/clientCapabilities": [:],
        ]
    }

    /// Encodes a header value; non-plain-ASCII (or sentinel-like) values use
    /// the `=?base64?…?=` form from the spec.
    public static func headerValue(_ value: String) -> String {
        let plain = value.unicodeScalars.allSatisfy { ($0.value >= 0x20 && $0.value <= 0x7E) || $0 == "\t" }
        let padded = value.first?.isWhitespace == true || value.last?.isWhitespace == true
        let sentinel = value.hasPrefix("=?base64?") && value.hasSuffix("?=")
        if plain && !padded && !sentinel { return value }
        return "=?base64?\(Data(value.utf8).base64EncodedString())?="
    }

    /// Decodes a header value written by `headerValue`.
    public static func decodeHeaderValue(_ value: String) -> String {
        guard value.hasPrefix("=?base64?"), value.hasSuffix("?="),
              let data = Data(base64Encoded: String(value.dropFirst(9).dropLast(2))),
              let s = String(data: data, encoding: .utf8) else { return value }
        return s
    }
}

public struct MCPError: Error, LocalizedError, Equatable, Sendable {
    public var code: Int?
    public var message: String
    public var data: JSONValue?
    public var httpStatus: Int?

    public init(code: Int? = nil, message: String, data: JSONValue? = nil, httpStatus: Int? = nil) {
        self.code = code
        self.message = message
        self.data = data
        self.httpStatus = httpStatus
    }

    /// A JSON-RPC error that only a modern-era server would send.
    public var isModern: Bool { code.map(MCPProtocol.modernErrorCodes.contains) ?? false }

    public var errorDescription: String? {
        if httpStatus == 401 || httpStatus == 403 && code == nil {
            return "The server refused access (HTTP \(httpStatus!)). Check the token or header in Settings › MCP."
        }
        return message
    }
}

/// A tool offered by an MCP server.
public struct MCPTool: Sendable, Hashable {
    public var name: String
    public var title: String?
    public var description: String
    public var inputSchema: JSONValue
    public var readOnly: Bool
    public var destructive: Bool

    public init(name: String, title: String? = nil, description: String, inputSchema: JSONValue, readOnly: Bool = false, destructive: Bool = true) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.readOnly = readOnly
        self.destructive = destructive
    }

    /// Parses a `tools/list` entry. Returns nil for invalid definitions
    /// (e.g. bad `x-mcp-header` annotations, which the spec says to exclude).
    public static func parse(_ json: JSONValue) -> MCPTool? {
        guard let name = json["name"]?.stringValue, !name.isEmpty else { return nil }
        let schema = json["inputSchema"] ?? ["type": "object"]
        guard MCPHeaders.validate(schema) else { return nil }
        let annotations = json["annotations"]
        let readOnly = annotations?["readOnlyHint"]?.boolValue ?? false
        let destructive = annotations?["destructiveHint"]?.boolValue ?? !readOnly
        return MCPTool(name: name, title: json["title"]?.stringValue ?? annotations?["title"]?.stringValue,
                       description: json["description"]?.stringValue ?? "", inputSchema: schema,
                       readOnly: readOnly, destructive: destructive)
    }

    public var json: JSONValue {
        var o: [String: JSONValue] = ["name": .string(name), "description": .string(description), "inputSchema": inputSchema,
                                      "annotations": ["readOnlyHint": .bool(readOnly), "destructiveHint": .bool(destructive)]]
        if let title { o["title"] = .string(title) }
        return .object(o)
    }
}

public struct MCPResource: Sendable, Hashable {
    public var uri: String
    public var name: String
    public var description: String?
    public var mimeType: String?

    public init(uri: String, name: String, description: String? = nil, mimeType: String? = nil) {
        self.uri = uri
        self.name = name
        self.description = description
        self.mimeType = mimeType
    }

    public var json: JSONValue {
        var o: [String: JSONValue] = ["uri": .string(uri), "name": .string(name)]
        if let description { o["description"] = .string(description) }
        if let mimeType { o["mimeType"] = .string(mimeType) }
        return .object(o)
    }
}

/// A tool result reduced to text for a model.
public struct MCPToolResult: Sendable, Equatable {
    public var text: String
    public var isError: Bool

    public init(text: String, isError: Bool) {
        self.text = text
        self.isError = isError
    }

    /// Flattens MCP content blocks: text as-is, structured content as JSON,
    /// other blocks as short placeholders.
    public static func from(_ result: JSONValue) -> MCPToolResult {
        var parts: [String] = []
        for block in result["content"]?.arrayValue ?? [] {
            switch block["type"]?.stringValue {
            case "text": parts.append(block["text"]?.stringValue ?? "")
            case "image": parts.append("[image: \(block["mimeType"]?.stringValue ?? "image")]")
            case "audio": parts.append("[audio: \(block["mimeType"]?.stringValue ?? "audio")]")
            case "resource_link": parts.append("[resource: \(block["uri"]?.stringValue ?? "") \(block["name"]?.stringValue ?? "")]")
            case "resource":
                let r = block["resource"]
                parts.append(r?["text"]?.stringValue ?? "[resource: \(r?["uri"]?.stringValue ?? "")]")
            default: break
            }
        }
        if parts.isEmpty, let structured = result["structuredContent"] { parts.append(structured.compactString) }
        return MCPToolResult(text: parts.joined(separator: "\n"), isError: result["isError"]?.boolValue ?? false)
    }
}

/// `x-mcp-header` handling (Streamable HTTP, 2026-07-28).
public enum MCPHeaders {
    /// Validates every `x-mcp-header` annotation in a tool schema.
    public static func validate(_ schema: JSONValue) -> Bool {
        var names = Set<String>()
        return walk(schema, reachable: true, names: &names)
    }

    private static func walk(_ schema: JSONValue, reachable: Bool, names: inout Set<String>) -> Bool {
        guard let object = schema.objectValue else { return true }
        if let header = object["x-mcp-header"] {
            guard reachable, let name = header.stringValue, isToken(name),
                  ["string", "integer", "boolean"].contains(object["type"]?.stringValue ?? ""),
                  names.insert(name.lowercased()).inserted else { return false }
        }
        for (key, value) in object {
            if key == "properties", let props = value.objectValue {
                for child in props.values where !walk(child, reachable: reachable, names: &names) { return false }
            } else if ["items", "anyOf", "oneOf", "allOf", "not", "if", "then", "else", "$defs", "additionalProperties"].contains(key) {
                let children = value.arrayValue ?? (value.objectValue.map { key == "$defs" ? Array($0.values) : [value] } ?? [])
                for child in children where !walk(child, reachable: false, names: &names) { return false }
            }
        }
        return true
    }

    static func isToken(_ s: String) -> Bool {
        let allowed = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return !s.isEmpty && s.allSatisfy { allowed.contains($0) }
    }

    /// `Mcp-Param-*` headers for a tool call's arguments.
    public static func paramHeaders(schema: JSONValue, arguments: JSONValue) -> [String: String] {
        var out: [String: String] = [:]
        func visit(_ schema: JSONValue, _ value: JSONValue?) {
            guard let props = schema["properties"]?.objectValue else { return }
            for (key, child) in props {
                let v = value?[key]
                if let header = child["x-mcp-header"]?.stringValue, let v {
                    switch v {
                    case .string(let s): out["Mcp-Param-\(header)"] = MCPProtocol.headerValue(s)
                    case .bool(let b): out["Mcp-Param-\(header)"] = b ? "true" : "false"
                    case .number(let n) where n.rounded() == n: out["Mcp-Param-\(header)"] = String(Int64(n))
                    default: break
                    }
                }
                if child["properties"] != nil { visit(child, v) }
            }
        }
        visit(schema, arguments)
        return out
    }
}
