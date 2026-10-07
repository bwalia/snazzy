import Foundation
import SnazzyCore

/// What an MCP server exposes. Snazzy Pro implements this with its own tools.
public protocol MCPServerBackend: Sendable {
    func tools() async -> [MCPTool]
    func callTool(name: String, arguments: JSONValue) async -> MCPToolResult
    func resources() async -> [MCPResource]
    func readResource(uri: String) async -> (text: String, mimeType: String)?
}

/// Protocol logic for an MCP server, independent of the transport.
/// Dual-era: modern stateless requests (per-request `_meta`) and the legacy
/// `initialize` handshake are both served on the same endpoint.
public struct MCPServerCore: Sendable {
    public struct Response: Sendable, Equatable {
        public var status: Int
        public var body: JSONValue?
        public var headers: [String: String]

        public init(status: Int, body: JSONValue?, headers: [String: String] = [:]) {
            self.status = status
            self.body = body
            self.headers = headers
        }
    }

    public let name: String
    public let version: String
    public let instructions: String
    public let backend: any MCPServerBackend

    public init(name: String, version: String, instructions: String, backend: any MCPServerBackend) {
        self.name = name
        self.version = version
        self.instructions = instructions
        self.backend = backend
    }

    var serverInfo: JSONValue { MCPProtocol.implementation(name, version) }
    var capabilities: JSONValue { ["tools": [:], "resources": [:]] }

    /// Handles one POSTed JSON-RPC message. Header names must be lower-cased.
    public func handle(body: Data, headers: [String: String]) async -> Response {
        guard let message = try? JSONValue.parse(body), message.objectValue != nil else {
            return error(nil, -32700, "Parse error", status: 400)
        }
        let id = message["id"]
        guard let method = message["method"]?.stringValue else {
            return error(id, -32600, "Invalid request: no method", status: 400)
        }
        // Notifications (no id): accept.
        if id == nil || id == .null { return Response(status: 202, body: nil) }

        let params = message["params"] ?? [:]
        let meta = params["_meta"]
        let bodyVersion = meta?["io.modelcontextprotocol/protocolVersion"]?.stringValue
        let headerVersion = headers["mcp-protocol-version"]

        // Legacy handshake.
        if method == "initialize" {
            let requested = params["protocolVersion"]?.stringValue ?? MCPProtocol.legacyVersions[0]
            let chosen = MCPProtocol.legacyVersions.contains(requested) ? requested : MCPProtocol.legacyVersions[0]
            return Response(status: 200, body: result(id, [
                "protocolVersion": .string(chosen),
                "capabilities": capabilities,
                "serverInfo": serverInfo,
                "instructions": .string(instructions),
            ], legacy: true), headers: ["Mcp-Session-Id": UUID().uuidString])
        }

        let isModern: Bool
        if let bodyVersion {
            guard bodyVersion == MCPProtocol.modernVersion else {
                return Response(status: 400, body: errorBody(id, MCPProtocol.unsupportedVersion, "Unsupported protocol version",
                    data: ["supported": .array(MCPProtocol.allVersions.map { .string($0) }), "requested": .string(bodyVersion)]))
            }
            // Mirrored headers must match the body.
            if let mismatch = headerMismatch(method: method, params: params, version: bodyVersion, headers: headers) {
                return error(id, MCPProtocol.headerMismatch, mismatch, status: 400)
            }
            guard meta?["io.modelcontextprotocol/clientCapabilities"] != nil else {
                return error(id, MCPProtocol.invalidParams, "Missing io.modelcontextprotocol/clientCapabilities in _meta", status: 400)
            }
            isModern = true
        } else if headers["mcp-session-id"] != nil || (headerVersion.map(MCPProtocol.legacyVersions.contains) ?? false) || headerVersion == nil {
            isModern = false  // legacy client after initialize
        } else {
            return error(id, MCPProtocol.invalidParams, "Missing _meta protocol fields", status: 400)
        }

        switch method {
        case "server/discover":
            return Response(status: 200, body: result(id, [
                "supportedVersions": .array(MCPProtocol.allVersions.map { .string($0) }),
                "capabilities": capabilities,
                "instructions": .string(instructions),
            ], legacy: !isModern))
        case "ping":
            return Response(status: 200, body: result(id, [:], legacy: !isModern))
        case "tools/list":
            let tools = await backend.tools()
            return Response(status: 200, body: result(id, ["tools": .array(tools.map(\.json))], legacy: !isModern))
        case "tools/call":
            guard let name = params["name"]?.stringValue else { return error(id, MCPProtocol.invalidParams, "Missing tool name", status: 400) }
            guard await backend.tools().contains(where: { $0.name == name }) else {
                return error(id, MCPProtocol.invalidParams, "Unknown tool: \(name)", status: 400)
            }
            let r = await backend.callTool(name: name, arguments: params["arguments"] ?? [:])
            return Response(status: 200, body: result(id, [
                "content": [["type": "text", "text": .string(r.text)]],
                "isError": .bool(r.isError),
            ], legacy: !isModern))
        case "resources/list":
            let resources = await backend.resources()
            return Response(status: 200, body: result(id, ["resources": .array(resources.map(\.json))], legacy: !isModern))
        case "resources/read":
            guard let uri = params["uri"]?.stringValue, let r = await backend.readResource(uri: uri) else {
                return error(id, MCPProtocol.invalidParams, "Resource not found", status: isModern ? 400 : 200)
            }
            return Response(status: 200, body: result(id, [
                "contents": [["uri": .string(uri), "mimeType": .string(r.mimeType), "text": .string(r.text)]],
            ], legacy: !isModern))
        default:
            return error(id, MCPProtocol.methodNotFound, "Method not found: \(method)", status: isModern ? 404 : 200)
        }
    }

    private func headerMismatch(method: String, params: JSONValue, version: String, headers: [String: String]) -> String? {
        guard let hv = headers["mcp-protocol-version"] else { return "Missing MCP-Protocol-Version header" }
        guard hv == version else { return "MCP-Protocol-Version header '\(hv)' does not match body '\(version)'" }
        guard let hm = headers["mcp-method"] else { return "Missing Mcp-Method header" }
        guard hm == method else { return "Mcp-Method header '\(hm)' does not match body '\(method)'" }
        if ["tools/call", "resources/read", "prompts/get"].contains(method) {
            let bodyName = params["name"]?.stringValue ?? params["uri"]?.stringValue ?? ""
            guard let hn = headers["mcp-name"] else { return "Missing Mcp-Name header" }
            guard MCPProtocol.decodeHeaderValue(hn) == bodyName else { return "Mcp-Name header does not match body" }
        }
        return nil
    }

    private func result(_ id: JSONValue?, _ fields: [String: JSONValue], legacy: Bool) -> JSONValue {
        var r = fields
        if !legacy {
            r["resultType"] = "complete"
            r["_meta"] = ["io.modelcontextprotocol/serverInfo": serverInfo]
        }
        return ["jsonrpc": "2.0", "id": id ?? .null, "result": .object(r)]
    }

    private func errorBody(_ id: JSONValue?, _ code: Int, _ message: String, data: JSONValue? = nil) -> JSONValue {
        var e: [String: JSONValue] = ["code": .number(Double(code)), "message": .string(message)]
        if let data { e["data"] = data }
        var o: [String: JSONValue] = ["jsonrpc": "2.0", "error": .object(e)]
        if let id, id != .null { o["id"] = id }
        return .object(o)
    }

    private func error(_ id: JSONValue?, _ code: Int, _ message: String, status: Int) -> Response {
        Response(status: status, body: errorBody(id, code, message))
    }
}
