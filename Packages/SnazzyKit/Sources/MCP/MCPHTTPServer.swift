import Foundation
import Network
import SnazzyCore

/// Serves an `MCPServerCore` over Streamable HTTP on 127.0.0.1 only.
///
/// Security: binds to loopback; every request needs `Authorization: Bearer
/// <token>`; the `Host` must be localhost and any `Origin` must be a localhost
/// origin (DNS-rebinding protection, as the spec requires).
public final class MCPHTTPServer: @unchecked Sendable {
    public let port: UInt16
    private let token: String
    private let handler: @Sendable (Data, [String: String]) async -> MCPServerCore.Response
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.snazzy.pro.mcp-server")
    public static let path = "/mcp"
    static let maxBody = 8_000_000

    public convenience init(port: UInt16, token: String, core: MCPServerCore) {
        self.init(port: port, token: token) { body, headers in await core.handle(body: body, headers: headers) }
    }

    /// Any JSON-RPC handler (used by tests to imitate other servers).
    public init(port: UInt16, token: String, handler: @escaping @Sendable (Data, [String: String]) async -> MCPServerCore.Response) {
        self.port = port
        self.token = token
        self.handler = handler
    }

    public var endpoint: String { "http://127.0.0.1:\(port)\(Self.path)" }

    public func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                Log.app.error("MCP server failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequest.parse(buffer) {
            case .complete(let request):
                Task { await self.respond(to: request, on: connection) }
            case .incomplete where !isComplete && error == nil && buffer.count < Self.maxBody:
                self.receive(connection, buffer: buffer)
            default:
                self.send(HTTPResponse(status: 400, body: Data("Bad request".utf8), contentType: "text/plain"), on: connection)
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) async {
        send(await handle(request), on: connection)
    }

    /// Routing and security checks (internal for tests).
    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let h = request.headers
        // DNS rebinding protection.
        let host = (h["host"] ?? "").lowercased()
        guard host == "127.0.0.1:\(port)" || host == "localhost:\(port)" || host == "127.0.0.1" || host == "localhost" else {
            return HTTPResponse(status: 403, body: Data("Forbidden host".utf8), contentType: "text/plain")
        }
        if let origin = h["origin"]?.lowercased(), !Self.isLocalOrigin(origin) {
            return HTTPResponse(status: 403, body: Data(#"{"jsonrpc":"2.0","error":{"code":-32600,"message":"Forbidden origin"}}"#.utf8))
        }
        guard request.path.split(separator: "?").first.map(String.init) == Self.path else {
            return HTTPResponse(status: 404, body: Data("Not found".utf8), contentType: "text/plain")
        }
        guard h["authorization"] == "Bearer \(token)" else {
            return HTTPResponse(status: 401, body: Data(#"{"jsonrpc":"2.0","error":{"code":-32600,"message":"Unauthorized: missing or wrong bearer token"}}"#.utf8),
                                extraHeaders: ["WWW-Authenticate": "Bearer"])
        }
        switch request.method {
        case "POST":
            let r = await handler(request.body, h)
            let body = try? r.body?.encoded(sortedKeys: false)
            return HTTPResponse(status: r.status, body: body ?? Data(), extraHeaders: r.headers)
        case "DELETE":
            return HTTPResponse(status: 200, body: Data())  // legacy session end: nothing to clean up
        default:
            return HTTPResponse(status: 405, body: Data(), extraHeaders: ["Allow": "POST"])
        }
    }

    static func isLocalOrigin(_ origin: String) -> Bool {
        guard let url = URL(string: origin), let host = url.host()?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "[::1]" || host == "::1"
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// A minimal HTTP/1.1 request (headers lower-cased).
struct HTTPRequest: Equatable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    enum ParseResult: Equatable {
        case complete(HTTPRequest)
        case incomplete
        case invalid
    }

    static func parse(_ data: Data) -> ParseResult {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length >= 0, length <= MCPHTTPServer.maxBody else { return .invalid }
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return .incomplete }
        let body = data[bodyStart..<(bodyStart + length)]
        return .complete(HTTPRequest(method: String(parts[0]), path: String(parts[1]), headers: headers, body: Data(body)))
    }
}

struct HTTPResponse: Equatable {
    var status: Int
    var body: Data
    var contentType = "application/json"
    var extraHeaders: [String: String] = [:]

    var serialized: Data {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                      404: "Not Found", 405: "Method Not Allowed"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if !body.isEmpty { head += "Content-Type: \(contentType)\r\n" }
        for (k, v) in extraHeaders.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}
