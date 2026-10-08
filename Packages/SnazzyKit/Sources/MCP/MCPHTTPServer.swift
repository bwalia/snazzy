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
    /// The listener stopped working after `start` (e.g. the port was taken).
    public var onFailed: (@Sendable (String) -> Void)?

    public func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                Log.app.error("MCP server failed: \(error.localizedDescription, privacy: .public)")
                self?.onFailed?("The server stopped: \(error.localizedDescription)")
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
            switch HTTPRequest.parse(buffer, maxBody: Self.maxBody) {
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
        guard !token.isEmpty, h["authorization"] == "Bearer \(token)" else {
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

