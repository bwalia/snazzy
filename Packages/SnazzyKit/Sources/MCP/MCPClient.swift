import Foundation
import SnazzyCore

/// A client for one MCP server over Streamable HTTP.
///
/// It first tries the modern protocol (`server/discover` with per-request
/// `_meta`). If the server answers with anything other than a modern result
/// or modern error, it falls back to the legacy `initialize` handshake and
/// sessions, as the spec's backward-compatibility rules describe.
public actor MCPClient {
    public enum Era: Sendable, Equatable {
        case modern(version: String)
        case legacy(version: String)
    }

    public let url: URL
    private let headers: [String: String]
    private let session: URLSession
    private let clientName: String
    private let clientVersion: String

    public private(set) var era: Era?
    public private(set) var serverName: String?
    public private(set) var instructions: String?
    public private(set) var capabilities: JSONValue = [:]
    private var sessionID: String?
    private var nextID = 1
    private var toolSchemas: [String: JSONValue] = [:]

    public static let timeout: TimeInterval = 60

    public init(url: URL, headers: [String: String] = [:], session: URLSession = .shared,
                clientName: String = "Snazzy Pro", clientVersion: String = "1.0") {
        self.url = url
        self.headers = headers
        self.session = session
        self.clientName = clientName
        self.clientVersion = clientVersion
    }

    // MARK: Connecting

    /// Works out which protocol era the server speaks and gets its identity.
    public func connect() async throws {
        do {
            let result = try await modern("server/discover", params: [:])
            let supported = result["supportedVersions"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if !supported.isEmpty, !supported.contains(MCPProtocol.modernVersion) {
                // A modern-shaped answer without our version: use legacy if offered.
                guard let legacy = MCPProtocol.legacyVersions.first(where: supported.contains) else {
                    throw MCPError(message: "The server supports MCP \(supported.joined(separator: ", ")), which Snazzy Pro doesn't.")
                }
                try await initializeLegacy(preferred: legacy)
                return
            }
            era = .modern(version: MCPProtocol.modernVersion)
            capabilities = result["capabilities"] ?? [:]
            instructions = result["instructions"]?.stringValue
            serverName = result["_meta"]?["io.modelcontextprotocol/serverInfo"]?["name"]?.stringValue
        } catch let error as MCPError where error.isModern {
            if error.code == MCPProtocol.unsupportedVersion,
               let supported = error.data?["supported"]?.arrayValue?.compactMap(\.stringValue),
               let legacy = MCPProtocol.legacyVersions.first(where: supported.contains) {
                try await initializeLegacy(preferred: legacy)
            } else {
                throw error
            }
        } catch let error as MCPError where error.httpStatus == 401 {
            throw error
        } catch {
            // Not a modern server (or a transport failure): try the legacy handshake.
            do {
                try await initializeLegacy(preferred: MCPProtocol.legacyVersions[0])
            } catch let legacyError {
                throw legacyError
            }
        }
    }

    private func initializeLegacy(preferred: String) async throws {
        sessionID = nil
        era = .legacy(version: preferred)
        let result = try await legacy("initialize", params: [
            "protocolVersion": .string(preferred),
            "capabilities": [:],
            "clientInfo": MCPProtocol.implementation(clientName, clientVersion),
        ], isInitialize: true)
        let version = result["protocolVersion"]?.stringValue ?? preferred
        guard MCPProtocol.legacyVersions.contains(version) else {
            throw MCPError(message: "The server wants MCP \(version), which Snazzy Pro doesn't support.")
        }
        era = .legacy(version: version)
        capabilities = result["capabilities"] ?? [:]
        instructions = result["instructions"]?.stringValue
        serverName = result["serverInfo"]?["name"]?.stringValue
        try await notifyLegacy("notifications/initialized")
    }

    // MARK: Operations

    public func listTools() async throws -> [MCPTool] {
        var tools: [MCPTool] = []
        var cursor: String?
        var seen: Set<String> = []
        repeat {
            var params: [String: JSONValue] = [:]
            if let cursor { params["cursor"] = .string(cursor) }
            let result = try await call("tools/list", params: .object(params))
            for item in result["tools"]?.arrayValue ?? [] {
                if let tool = MCPTool.parse(item) {
                    tools.append(tool)
                    toolSchemas[tool.name] = tool.inputSchema
                } else {
                    Log.assistant.notice("MCP: skipped invalid tool definition \(item["name"]?.stringValue ?? "?", privacy: .public)")
                }
            }
            cursor = result["nextCursor"]?.stringValue
            // A server that repeats a cursor (or pages forever) can't keep us looping.
        } while cursor.map({ seen.insert($0).inserted }) == true && seen.count < 100 && tools.count < 1000
        return tools
    }

    public func callTool(_ name: String, arguments: JSONValue) async throws -> MCPToolResult {
        let result = try await call("tools/call", params: ["name": .string(name), "arguments": arguments], name: name,
                                    paramHeaders: MCPHeaders.paramHeaders(schema: toolSchemas[name] ?? [:], arguments: arguments))
        return MCPToolResult.from(result)
    }

    public func listResources() async throws -> [MCPResource] {
        var resources: [MCPResource] = []
        var cursor: String?
        var seen: Set<String> = []
        repeat {
            var params: [String: JSONValue] = [:]
            if let cursor { params["cursor"] = .string(cursor) }
            let result = try await call("resources/list", params: .object(params))
            for item in result["resources"]?.arrayValue ?? [] {
                guard let uri = item["uri"]?.stringValue else { continue }
                resources.append(MCPResource(uri: uri, name: item["name"]?.stringValue ?? uri,
                                             description: item["description"]?.stringValue, mimeType: item["mimeType"]?.stringValue))
            }
            cursor = result["nextCursor"]?.stringValue
        } while cursor.map({ seen.insert($0).inserted }) == true && seen.count < 100 && resources.count < 2000
        return resources
    }

    /// Text of a resource (binary contents are summarised).
    public func readResource(_ uri: String) async throws -> String {
        let result = try await call("resources/read", params: ["uri": .string(uri)], name: uri)
        return (result["contents"]?.arrayValue ?? []).map { item in
            if let text = item["text"]?.stringValue { return text }
            return "[\(item["mimeType"]?.stringValue ?? "binary") content, \(item["blob"]?.stringValue?.count ?? 0) base64 chars]"
        }.joined(separator: "\n\n")
    }

    /// Ends a legacy session (modern servers are stateless).
    public func close() async {
        guard case .legacy = era, let sessionID else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        _ = try? await session.data(for: request)
        self.sessionID = nil
    }

    // MARK: Requests

    private func call(_ method: String, params: JSONValue, name: String? = nil, paramHeaders: [String: String] = [:]) async throws -> JSONValue {
        if era == nil { try await connect() }
        switch era {
        case .legacy:
            do {
                return try await legacy(method, params: params)
            } catch let error as MCPError where error.httpStatus == 404 && sessionID != nil {
                // Session expired: start a new one and retry once.
                try await initializeLegacy(preferred: MCPProtocol.legacyVersions[0])
                return try await legacy(method, params: params)
            }
        default:
            return try await modern(method, params: params, name: name, paramHeaders: paramHeaders)
        }
    }

    private func modern(_ method: String, params: JSONValue, name: String? = nil, paramHeaders: [String: String] = [:]) async throws -> JSONValue {
        var p = params.objectValue ?? [:]
        p["_meta"] = MCPProtocol.requestMeta(clientName: clientName, clientVersion: clientVersion)
        var extra = paramHeaders
        extra["MCP-Protocol-Version"] = MCPProtocol.modernVersion
        extra["Mcp-Method"] = method
        if let name { extra["Mcp-Name"] = MCPProtocol.headerValue(name) }
        return try await post(method: method, params: .object(p), headers: extra)
    }

    private func legacy(_ method: String, params: JSONValue, isInitialize: Bool = false) async throws -> JSONValue {
        var extra: [String: String] = [:]
        if !isInitialize, case .legacy(let version) = era { extra["MCP-Protocol-Version"] = version }
        if let sessionID { extra["Mcp-Session-Id"] = sessionID }
        return try await post(method: method, params: params, headers: extra, captureSession: isInitialize)
    }

    private func notifyLegacy(_ method: String) async throws {
        var request = baseRequest()
        if case .legacy(let version) = era { request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version") }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = try (["jsonrpc": "2.0", "method": .string(method)] as JSONValue).encoded(sortedKeys: false)
        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw MCPError(message: "The server rejected \(method) (HTTP \(status)).", httpStatus: status) }
    }

    private func baseRequest() -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        return request
    }

    private func post(method: String, params: JSONValue, headers extra: [String: String], captureSession: Bool = false) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        var request = baseRequest()
        for (k, v) in extra { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = try (["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params] as JSONValue)
            .encoded(sortedKeys: false)

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch let error as URLError {
            throw MCPError(message: "Can't reach \(url.host() ?? "the server"): \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else { throw MCPError(message: "Not an HTTP response") }
        if captureSession, let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = sid }
        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""

        var message: JSONValue?
        if contentType.contains("text/event-stream") {
            message = try await Self.readSSE(bytes, id: id)
        } else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 20_000_000 { throw MCPError(message: "Response too large") }
            }
            message = try? JSONValue.parse(data)
            if message == nil, !(200..<300).contains(http.statusCode) {
                throw MCPError(message: "HTTP \(http.statusCode) from \(url.host() ?? "server")" +
                               (data.isEmpty ? "" : ": \(String(decoding: data.prefix(200), as: UTF8.self))"), httpStatus: http.statusCode)
            }
        }
        guard let message else { throw MCPError(message: "Empty response to \(method)", httpStatus: http.statusCode) }
        if let error = message["error"] {
            throw MCPError(code: error["code"]?.intValue, message: error["message"]?.stringValue ?? "MCP error",
                           data: error["data"], httpStatus: http.statusCode)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MCPError(message: "HTTP \(http.statusCode) from \(url.host() ?? "server")", httpStatus: http.statusCode)
        }
        guard let result = message["result"] else { throw MCPError(message: "No result in response to \(method)") }
        if result["resultType"]?.stringValue == "input_required" {
            throw MCPError(message: "The server asked for extra input (sampling or elicitation), which Snazzy Pro doesn't support yet.")
        }
        return result
    }

    /// Reads SSE `data:` lines until the JSON-RPC response with `id` arrives
    /// (notifications before it are skipped).
    static func readSSE(_ bytes: URLSession.AsyncBytes, id: Int) async throws -> JSONValue? {
        var buffer = ""
        var total = 0
        for try await line in bytes.lines {
            // Same limit as a plain JSON response, however the stream is split up.
            total += line.utf8.count
            if total > 20_000_000 { throw MCPError(message: "Response too large") }
            if line.hasPrefix(":") || line.hasPrefix("event:") || line.hasPrefix("id:") || line.hasPrefix("retry:") { continue }
            guard line.hasPrefix("data:") else { continue }
            let chunk = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            buffer += buffer.isEmpty ? chunk : "\n" + chunk
            guard let message = try? JSONValue.parse(buffer) else { continue }  // multi-line data: keep reading
            buffer = ""
            if message["id"]?.intValue == id || message["id"]?.stringValue == String(id) { return message }
        }
        return nil
    }
}
