import Foundation
import Testing
@testable import MCP
@testable import SnazzyCore

/// A small backend with one read-only tool, one destructive tool and a resource.
struct TestBackend: MCPServerBackend {
    func tools() async -> [MCPTool] {
        [
            MCPTool(name: "echo", description: "Echo text", inputSchema: [
                "type": "object", "properties": ["text": ["type": "string"], "region": ["type": "string", "x-mcp-header": "Region"]],
                "required": ["text"],
            ], readOnly: true, destructive: false),
            MCPTool(name: "délete", description: "Non-ASCII name", inputSchema: ["type": "object"]),
        ]
    }
    func callTool(name: String, arguments: JSONValue) async -> MCPToolResult {
        name == "echo" ? MCPToolResult(text: "echo: \(arguments["text"]?.stringValue ?? "")", isError: false)
                       : MCPToolResult(text: "deleted", isError: false)
    }
    func resources() async -> [MCPResource] { [MCPResource(uri: "test://notes", name: "Notes", mimeType: "text/plain")] }
    func readResource(uri: String) async -> (text: String, mimeType: String)? { uri == "test://notes" ? ("Q3: deploys +40%", "text/plain") : nil }
}

func core() -> MCPServerCore { MCPServerCore(name: "Test", version: "1", instructions: "Test server", backend: TestBackend()) }

func modernHeaders(_ method: String, name: String? = nil) -> [String: String] {
    var h = ["mcp-protocol-version": MCPProtocol.modernVersion, "mcp-method": method]
    if let name { h["mcp-name"] = MCPProtocol.headerValue(name) }
    return h
}

func request(_ method: String, _ params: JSONValue = [:], modern: Bool = true) -> Data {
    var p = params.objectValue ?? [:]
    if modern { p["_meta"] = MCPProtocol.requestMeta(clientName: "t", clientVersion: "1") }
    return try! (["jsonrpc": "2.0", "id": 7, "method": .string(method), "params": .object(p)] as JSONValue).encoded()
}

@Suite struct MCPProtocolTests {
    @Test func headerValueEncoding() {
        #expect(MCPProtocol.headerValue("us-west1") == "us-west1")
        #expect(MCPProtocol.headerValue("Hello, 世界") == "=?base64?SGVsbG8sIOS4lueVjA==?=")
        #expect(MCPProtocol.headerValue(" padded ") == "=?base64?IHBhZGRlZCA=?=")
        #expect(MCPProtocol.headerValue("line1\nline2") == "=?base64?bGluZTEKbGluZTI=?=")
        #expect(MCPProtocol.headerValue("=?base64?literal?=") == "=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=")
        #expect(MCPProtocol.decodeHeaderValue("=?base64?SGVsbG8sIOS4lueVjA==?=") == "Hello, 世界")
    }

    @Test func xMcpHeaderValidationAndExtraction() {
        let good: JSONValue = ["type": "object", "properties": [
            "region": ["type": "string", "x-mcp-header": "Region"],
            "opts": ["type": "object", "properties": ["dry": ["type": "boolean", "x-mcp-header": "Dry"]]],
        ]]
        #expect(MCPHeaders.validate(good))
        #expect(MCPHeaders.paramHeaders(schema: good, arguments: ["region": "eu", "opts": ["dry": true]])
                == ["Mcp-Param-Region": "eu", "Mcp-Param-Dry": "true"])
        let numberHeader: JSONValue = ["type": "object", "properties": ["n": ["type": "number", "x-mcp-header": "N"]]]
        let inArray: JSONValue = ["type": "object", "properties": ["a": ["type": "array", "items": ["type": "string", "x-mcp-header": "A"]]]]
        let duplicate: JSONValue = ["type": "object", "properties": ["a": ["type": "string", "x-mcp-header": "X"], "b": ["type": "string", "x-mcp-header": "x"]]]
        #expect(!MCPHeaders.validate(numberHeader))
        #expect(!MCPHeaders.validate(inArray))
        #expect(!MCPHeaders.validate(duplicate))
        #expect(MCPTool.parse(["name": "bad", "inputSchema": numberHeader]) == nil)
    }

    @Test func toolResultFlattening() {
        let r = MCPToolResult.from(["content": [["type": "text", "text": "a"], ["type": "image", "mimeType": "image/png", "data": "x"]], "isError": true])
        #expect(r == MCPToolResult(text: "a\n[image: image/png]", isError: true))
        #expect(MCPToolResult.from(["structuredContent": ["k": 1]]).text == #"{"k":1}"#)
    }
}

@Suite struct MCPServerCoreTests {
    @Test func discoverAndCall() async throws {
        let d = await core().handle(body: request("server/discover"), headers: modernHeaders("server/discover"))
        #expect(d.status == 200)
        #expect(d.body?["result"]?["resultType"] == "complete")
        #expect(d.body?["result"]?["supportedVersions"]?.arrayValue?.first == .string(MCPProtocol.modernVersion))

        let c = await core().handle(body: request("tools/call", ["name": "echo", "arguments": ["text": "hi"]]),
                                    headers: modernHeaders("tools/call", name: "echo"))
        #expect(c.body?["result"]?["content"]?.arrayValue?.first?["text"] == "echo: hi")
    }

    @Test func modernValidation() async {
        // Header/body mismatch → 400 -32020.
        let m = await core().handle(body: request("tools/call", ["name": "echo", "arguments": [:]]), headers: modernHeaders("tools/call", name: "other"))
        #expect(m.status == 400)
        #expect(m.body?["error"]?["code"]?.intValue == MCPProtocol.headerMismatch)
        // Unsupported version → 400 -32022 listing supported versions.
        var p: [String: JSONValue] = ["_meta": ["io.modelcontextprotocol/protocolVersion": "1900-01-01", "io.modelcontextprotocol/clientCapabilities": [:]]]
        p["x"] = 1
        let body = try! (["jsonrpc": "2.0", "id": 1, "method": "ping", "params": .object(p)] as JSONValue).encoded()
        let v = await core().handle(body: body, headers: ["mcp-protocol-version": "1900-01-01", "mcp-method": "ping"])
        #expect(v.status == 400)
        #expect(v.body?["error"]?["code"]?.intValue == MCPProtocol.unsupportedVersion)
        #expect(v.body?["error"]?["data"]?["supported"]?.arrayValue?.count == MCPProtocol.allVersions.count)
        // Unknown method → 404 -32601.
        let u = await core().handle(body: request("nope/nope"), headers: modernHeaders("nope/nope"))
        #expect(u.status == 404)
        #expect(u.body?["error"]?["code"]?.intValue == MCPProtocol.methodNotFound)
    }

    @Test func legacyHandshake() async {
        let i = await core().handle(body: request("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:]], modern: false), headers: [:])
        #expect(i.body?["result"]?["protocolVersion"] == "2025-06-18")
        #expect(i.headers["Mcp-Session-Id"] != nil)
        let n = await core().handle(body: try! (["jsonrpc": "2.0", "method": "notifications/initialized"] as JSONValue).encoded(), headers: [:])
        #expect(n.status == 202)
        let t = await core().handle(body: request("tools/list", modern: false), headers: ["mcp-session-id": "x", "mcp-protocol-version": "2025-06-18"])
        #expect(t.body?["result"]?["tools"]?.arrayValue?.count == 2)
        #expect(t.body?["result"]?["resultType"] == nil)
    }
}

@Suite(.serialized) struct MCPHTTPTests {
    func port() -> UInt16 { UInt16.random(in: 49_500...60_000) }

    @Test func securityChecks() async {
        let server = MCPHTTPServer(port: 50_001, token: "secret", core: core())
        func req(_ method: String = "POST", host: String = "127.0.0.1:50001", origin: String? = nil, auth: String? = "Bearer secret") -> HTTPRequest {
            var h = ["host": host]
            if let origin { h["origin"] = origin }
            if let auth { h["authorization"] = auth }
            return HTTPRequest(method: method, path: "/mcp", headers: h, body: request("ping"))
        }
        #expect(await server.handle(req(host: "evil.example:50001")).status == 403)
        #expect(await server.handle(req(origin: "https://evil.example")).status == 403)
        #expect(await server.handle(req(auth: nil)).status == 401)
        #expect(await server.handle(req(auth: "Bearer wrong")).status == 401)
        #expect(await server.handle(req("GET")).status == 405)
        #expect(await server.handle(req(origin: "http://localhost:3000")).status != 403)
        // No token (the Keychain couldn't be read) must never mean "anyone may connect".
        let tokenless = MCPHTTPServer(port: 50_002, token: "", core: core())
        #expect(await tokenless.handle(HTTPRequest(method: "POST", path: "/mcp", headers: ["host": "127.0.0.1:50002", "authorization": "Bearer "],
                                                   body: request("ping"))).status == 401)
    }

    @Test func httpParsing() {
        let raw = Data("POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello".utf8)
        #expect(HTTPRequest.parse(raw) == .complete(HTTPRequest(method: "POST", path: "/mcp", headers: ["host": "x", "content-length": "5"], body: Data("hello".utf8))))
        #expect(HTTPRequest.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: 5\r\n\r\nhe".utf8)) == .incomplete)
        #expect(HTTPRequest.parse(Data("POST /mcp".utf8)) == .incomplete)
    }

    @Test func modernClientAgainstServerOverHTTP() async throws {
        let p = port()
        let server = MCPHTTPServer(port: p, token: "tok", core: core())
        try server.start()
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(200))

        let client = MCPClient(url: URL(string: "http://127.0.0.1:\(p)/mcp")!, headers: ["Authorization": "Bearer tok"])
        try await client.connect()
        #expect(await client.era == .modern(version: MCPProtocol.modernVersion))
        let tools = try await client.listTools()
        #expect(tools.map(\.name) == ["echo", "délete"])
        #expect(tools[0].readOnly && !tools[0].destructive)
        #expect(try await client.callTool("echo", arguments: ["text": "hello", "region": "eu"]) == MCPToolResult(text: "echo: hello", isError: false))
        #expect(try await client.callTool("délete", arguments: [:]).text == "deleted")  // base64 Mcp-Name
        #expect(try await client.listResources().map(\.uri) == ["test://notes"])
        #expect(try await client.readResource("test://notes") == "Q3: deploys +40%")
    }

    @Test func wrongTokenIsReported() async throws {
        let p = port()
        let server = MCPHTTPServer(port: p, token: "tok", core: core())
        try server.start()
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(200))
        let client = MCPClient(url: URL(string: "http://127.0.0.1:\(p)/mcp")!, headers: ["Authorization": "Bearer nope"])
        await #expect(throws: MCPError.self) { try await client.connect() }
    }

    @Test func clientFallsBackToLegacyServer() async throws {
        // Imitates a 2025-06-18 server: no server/discover, needs initialize + session.
        let p = port()
        let legacyCore = core()
        let server = MCPHTTPServer(port: p, token: "tok") { body, headers in
            let message = (try? JSONValue.parse(body)) ?? [:]
            let method = message["method"]?.stringValue ?? ""
            if method == "initialize" || method.hasPrefix("notifications/") { return await legacyCore.handle(body: body, headers: headers) }
            guard headers["mcp-session-id"] != nil else {
                return .init(status: 400, body: ["jsonrpc": "2.0", "id": message["id"] ?? .null,
                                                 "error": ["code": -32000, "message": "Bad Request: No valid session ID provided"]])
            }
            return await legacyCore.handle(body: body, headers: headers)
        }
        try server.start()
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(200))

        let client = MCPClient(url: URL(string: "http://127.0.0.1:\(p)/mcp")!, headers: ["Authorization": "Bearer tok"])
        try await client.connect()
        #expect(await client.era == .legacy(version: "2025-11-25"))
        #expect(try await client.listTools().count == 2)
        #expect(try await client.callTool("echo", arguments: ["text": "legacy"]).text == "echo: legacy")
    }
}
