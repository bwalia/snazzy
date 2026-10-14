import CryptoKit
import Foundation
import Network
import SnazzyCore

/// Serves interviews to candidates' browsers on the local network: the page at
/// `/i/<token>` and a small JSON API beside it. The token is the only key; the
/// server keeps only its SHA-256 hash. Nothing goes through servers of ours.
public final class InterviewLinkServer: @unchecked Sendable {
    /// What a request asks for, after the token has been checked by the handler.
    public enum Action: Sendable {
        case state, start, answer, event, selfID
    }

    /// Answers one request: (token, action, JSON body) → (HTTP status, JSON).
    public typealias Handler = @Sendable (_ token: String, _ action: Action, _ body: JSONValue) async -> (Int, JSONValue)

    public static let ports: ClosedRange<UInt16> = 8795...8798
    static let maxBody = 32_000
    static let maxConnectionsPerDevice = 16
    static let requestTimeout: TimeInterval = 15

    public private(set) var port: UInt16 = 0
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.snazzy.pro.interview-server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var open: [String: Int] = [:]

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// A new link token: 256 random bits, URL-safe.
    public static func makeToken() -> String {
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Starts on the first free port in `ports`.
    public func start() async throws {
        var lastError: Error?
        for p in Self.ports {
            do {
                try await listen(on: p)
                port = p
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NWError.posix(.EADDRINUSE)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    public var isRunning: Bool { listener != nil }

    /// The link for a token, on this Mac's address on the local network.
    public func link(for token: String, host: String) -> URL? {
        URL(string: "http://\(host):\(port)/i/\(token)")
    }

    private func listen(on port: UInt16) async throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = false
        params.includePeerToPeer = false
        (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        let fired = Fired()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if fired.once() { cont.resume() }
                case .failed(let e), .waiting(let e):
                    if fired.once() { listener.cancel(); cont.resume(throwing: e) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        self.listener = listener
    }

    private final class Fired: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func once() -> Bool { lock.withLock { defer { done = true }; return !done } }
    }

    // MARK: Connections (one request each)

    private func accept(_ connection: NWConnection) {
        let device: String = if case .hostPort(let host, _) = connection.endpoint { "\(host)" } else { "unknown" }
        let ok = lock.withLock { () -> Bool in
            guard open[device, default: 0] < Self.maxConnectionsPerDevice else { return false }
            open[device, default: 0] += 1
            return true
        }
        guard ok else { return connection.cancel() }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed: connection.cancel()
            case .cancelled:
                self?.lock.withLock {
                    self?.open[device, default: 1] -= 1
                    if self?.open[device] == 0 { self?.open[device] = nil }
                }
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.requestTimeout) { [weak connection] in connection?.cancel() }
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
            case .incomplete where !isComplete && error == nil && buffer.count < Self.maxBody + 8_192:
                self.receive(connection, buffer: buffer)
            default:
                self.send(Self.text(400, "Bad request"), on: connection)
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) async {
        let parts = request.route.split(separator: "/").map(String.init)
        // /i/<token>, /i/<token>/<action>
        guard parts.count >= 2, parts[0] == "i", parts[1].count >= 32, parts[1].count <= 64,
              parts[1].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return send(Self.text(404, "Not found"), on: connection)
        }
        let token = parts[1]
        if parts.count == 2, request.method == "GET" {
            return send(HTTPResponse(status: 200, body: Data(CandidatePage.html.utf8), contentType: "text/html; charset=utf-8",
                                     extraHeaders: Self.pageHeaders), on: connection)
        }
        guard parts.count == 3 else { return send(Self.text(404, "Not found"), on: connection) }
        let action: Action
        switch (request.method, parts[2]) {
        case ("GET", "state"): action = .state
        case ("POST", "start"): action = .start
        case ("POST", "answer"): action = .answer
        case ("POST", "event"): action = .event
        case ("POST", "self-id"): action = .selfID
        default: return send(Self.text(404, "Not found"), on: connection)
        }
        if request.method == "POST" {
            // Same-origin pages only: a page elsewhere can't post into an interview.
            if let origin = request.headers["origin"], let host = request.headers["host"], origin != "http://\(host)" {
                return send(Self.text(403, "Forbidden"), on: connection)
            }
        }
        let body = request.body.isEmpty ? JSONValue.object([:]) : ((try? JSONValue.parse(request.body)) ?? .object([:]))
        let (status, json) = await handler(token, action, body)
        let data = (try? JSONEncoder().encode(json)) ?? Data("{}".utf8)
        send(HTTPResponse(status: status, body: data, contentType: "application/json", extraHeaders: ["Cache-Control": "no-store"]), on: connection)
    }

    static let pageHeaders = [
        "Cache-Control": "no-store",
        "Content-Security-Policy": "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src data:; form-action 'none'; frame-ancestors 'none'; base-uri 'none'",
        "Referrer-Policy": "no-referrer",
        "X-Content-Type-Options": "nosniff",
    ]

    static func text(_ status: Int, _ s: String) -> HTTPResponse {
        HTTPResponse(status: status, body: Data(s.utf8), contentType: "text/plain; charset=utf-8")
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized, completion: .contentProcessed { _ in connection.cancel() })
    }
}
