import Foundation
import Network
import SnazzyCore

/// The live room on the local network: serves the viewer page, the stream
/// (fMP4 segments, HLS playlist) and the brainstorm board, with live updates
/// over Server-Sent Events.
///
/// Access needs the room code (`?k=`), shown with the QR code on the Mac.
/// Nothing leaves the local network: there are no servers of ours.
public final class LiveServer: @unchecked Sendable {
    public let port: UInt16
    public let code: String
    public let segments: LiveSegments

    /// Called (on any queue) when the board changes from the room or the host.
    public var onBoardChange: (@Sendable (BrainstormBoard) -> Void)?
    /// Called when the number of connected viewers changes.
    public var onViewersChange: (@Sendable (Int) -> Void)?
    /// Called when the listener is ready or fails.
    public var onState: (@Sendable (String?) -> Void)?

    public static let maxViewers = 100
    static let maxBody = 16_000

    private let queue = DispatchQueue(label: "com.snazzy.pro.live-server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var board: BrainstormBoard
    private var status: JSONValue = ["live": false]
    private var subscribers: [ObjectIdentifier: (connection: NWConnection, voter: String)] = [:]
    private var keepAlive: DispatchSourceTimer?

    public init(port: UInt16 = 8787, code: String = LiveServer.makeCode(), board: BrainstormBoard = BrainstormBoard(), segments: LiveSegments = LiveSegments()) {
        self.port = port
        self.code = code
        self.board = board
        self.segments = segments
    }

    /// Six characters without look-alikes (no 0/O, 1/I/L).
    public static func makeCode() -> String {
        let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
        return String((0..<6).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }

    // MARK: Lifecycle

    /// Starts listening; returns once the port is open, or throws (e.g. port in use).
    public func start() async throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = false
        params.includePeerToPeer = false
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        let once = Once()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if once.fire() { cont.resume() } else { self?.onState?(nil) }
                case .failed(let e), .waiting(let e):
                    if once.fire() { listener.cancel(); cont.resume(throwing: e) } else { self?.onState?(e.localizedDescription) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        self.listener = listener
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in self?.broadcastRaw(Data(": keep-alive\n\n".utf8)) }
        timer.resume()
        keepAlive = timer
    }

    public func stop() {
        keepAlive?.cancel()
        keepAlive = nil
        listener?.cancel()
        listener = nil
        let subs = lock.withLock { () -> [NWConnection] in
            let c = subscribers.values.map(\.connection)
            subscribers.removeAll()
            return c
        }
        subs.forEach { $0.cancel() }
        onViewersChange?(0)
    }

    public var viewerCount: Int { lock.withLock { subscribers.count } }

    // MARK: Host

    public func currentBoard() -> BrainstormBoard { lock.withLock { board } }

    /// Changes the board from the Mac (moderation, topic, open/close).
    public func updateBoard(_ change: (inout BrainstormBoard) -> Void) {
        let snapshot = lock.withLock { () -> BrainstormBoard in
            change(&board)
            return board
        }
        boardChanged(snapshot)
    }

    /// What viewers see in the status line (live or not, current slide…).
    public func setStatus(_ status: JSONValue) {
        lock.withLock { self.status = status }
        broadcast(event: "status") { _ in status }
    }

    // MARK: Connections

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
                self.respond(to: request, on: connection)
            case .incomplete where !isComplete && error == nil && buffer.count < Self.maxBody + 8_192:
                self.receive(connection, buffer: buffer)
            default:
                self.send(HTTPResponse(status: 400, body: Data("Bad request".utf8), contentType: "text/plain"), on: connection)
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) {
        if request.method == "GET", request.route == "/api/events", authorized(request) {
            subscribe(connection, voter: Self.voter(request))
            return
        }
        send(handle(request), on: connection)
    }

    /// Routing (internal for tests). SSE is handled separately.
    func handle(_ request: HTTPRequest) -> HTTPResponse {
        let route = request.route
        // The page itself works without a code (it asks for one).
        if request.method == "GET", route == "/" || route == "/index.html" {
            return HTTPResponse(status: 200, body: Data(LiveViewerPage.html.utf8), contentType: "text/html; charset=utf-8",
                                extraHeaders: Self.pageHeaders)
        }
        if request.method == "GET", route == "/favicon.ico" { return HTTPResponse(status: 204, body: Data()) }
        guard authorized(request) else {
            return json(401, ["error": "Wrong or missing room code."])
        }
        let voter = Self.voter(request)
        switch (request.method, route) {
        case ("GET", "/api/board"):
            return json(200, lock.withLock { board.publicJSON(for: voter) })
        case ("GET", "/api/status"):
            return json(200, lock.withLock { status })
        case ("GET", "/live/status"):
            return json(200, segments.statusJSON(), cache: "no-store")
        case ("GET", "/live/stream.m3u8"):
            guard let list = segments.playlist(query: "k=\(code)") else { return json(404, ["error": "Not live yet."]) }
            return HTTPResponse(status: 200, body: Data(list.utf8), contentType: "application/vnd.apple.mpegurl",
                                extraHeaders: ["Cache-Control": "no-store"])
        case ("GET", "/live/init.mp4"):
            guard let data = segments.initData() else { return json(404, ["error": "Not live yet."]) }
            return HTTPResponse(status: 200, body: data, contentType: "video/mp4", extraHeaders: ["Cache-Control": "no-store"])
        case ("GET", let r) where r.hasPrefix("/live/seg-") && r.hasSuffix(".m4s"):
            let n = Int(r.dropFirst("/live/seg-".count).dropLast(".m4s".count)) ?? -1
            guard let seg = segments.segment(n) else { return json(404, ["error": "Segment gone."]) }
            return HTTPResponse(status: 200, body: seg.data, contentType: "video/iso.segment", extraHeaders: ["Cache-Control": "max-age=60"])
        case ("POST", "/api/notes"):
            guard let body = try? JSONValue.parse(request.body) else { return json(400, ["error": "Bad request."]) }
            return boardAction(voter: voter) { board in
                try board.add(text: body["text"]?.stringValue ?? "", author: body["name"]?.stringValue ?? "", poster: voter)
            }
        case ("POST", "/api/vote"):
            guard let body = try? JSONValue.parse(request.body), let id = body["id"]?.stringValue else { return json(400, ["error": "Bad request."]) }
            return boardAction(voter: voter) { board in try board.vote(id, voter: voter) }
        default:
            return json(404, ["error": "Not found."])
        }
    }

    private func boardAction(voter: String, _ action: (inout BrainstormBoard) throws -> Void) -> HTTPResponse {
        do {
            let snapshot = try lock.withLock { () throws -> BrainstormBoard in
                try action(&board)
                return board
            }
            boardChanged(snapshot)
            return json(200, snapshot.publicJSON(for: voter))
        } catch {
            let status = (error as? BrainstormBoard.BoardError) == .tooFast ? 429 : 409
            return json(status, ["error": .string(error.localizedDescription)])
        }
    }

    private func authorized(_ request: HTTPRequest) -> Bool {
        let given = request.query["k"] ?? request.headers["x-room-code"] ?? ""
        return Self.constantTimeEqual(given.uppercased(), code)
    }

    /// A per-browser ID from the page (random, kept in the browser), used for
    /// one vote per idea and post limits. Not an identity.
    static func voter(_ request: HTTPRequest) -> String {
        let raw = request.headers["x-snazzy-client"] ?? request.query["c"] ?? ""
        let clean = raw.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(64)
        return clean.isEmpty ? "anonymous" : String(clean)
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static let pageHeaders = [
        "Cache-Control": "no-store",
        "X-Content-Type-Options": "nosniff",
        "Referrer-Policy": "no-referrer",
        // Only our own inline page; no third-party anything.
        "Content-Security-Policy": "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; media-src 'self' blob:; img-src 'self' data:; connect-src 'self'",
    ]

    private func json(_ status: Int, _ value: JSONValue, cache: String = "no-store") -> HTTPResponse {
        HTTPResponse(status: status, body: (try? value.encoded(sortedKeys: false)) ?? Data(), extraHeaders: ["Cache-Control": cache])
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: Server-Sent Events

    private func subscribe(_ connection: NWConnection, voter: String) {
        let count = lock.withLock { subscribers.count }
        guard count < Self.maxViewers else {
            send(HTTPResponse(status: 503, body: Data(#"{"error":"The room is full."}"#.utf8)), on: connection)
            return
        }
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: keep-alive\r\nX-Accel-Buffering: no\r\n\r\nretry: 2000\n\n"
        let (b, s) = lock.withLock { (board.publicJSON(for: voter), status) }
        var first = Data(head.utf8)
        first.append(Self.event("board", b))
        first.append(Self.event("status", s))
        let id = ObjectIdentifier(connection)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.unsubscribe(id)
            default: break
            }
        }
        // Notice when the browser goes away (a read returns end of stream).
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, _, _ in
            self?.unsubscribe(id)
            connection.cancel()
        }
        let n = lock.withLock { () -> Int in
            subscribers[id] = (connection, voter)
            return subscribers.count
        }
        connection.send(content: first, completion: .contentProcessed { _ in })
        onViewersChange?(n)
    }

    private func unsubscribe(_ id: ObjectIdentifier) {
        let (removed, n) = lock.withLock { (subscribers.removeValue(forKey: id) != nil, subscribers.count) }
        if removed { onViewersChange?(n) }
    }

    static func event(_ name: String, _ value: JSONValue) -> Data {
        let json = (try? value.encoded(sortedKeys: false)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return Data("event: \(name)\ndata: \(json)\n\n".utf8)
    }

    private func boardChanged(_ snapshot: BrainstormBoard) {
        broadcast(event: "board") { voter in snapshot.publicJSON(for: voter) }
        onBoardChange?(snapshot)
    }

    private func broadcast(event: String, _ value: (String) -> JSONValue) {
        let subs = lock.withLock { Array(subscribers.values) }
        for sub in subs {
            sub.connection.send(content: Self.event(event, value(sub.voter)), completion: .contentProcessed { _ in })
        }
    }

    private func broadcastRaw(_ data: Data) {
        let subs = lock.withLock { subscribers.values.map(\.connection) }
        for c in subs { c.send(content: data, completion: .contentProcessed { _ in }) }
    }
}

/// Fires once (first caller wins).
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool { lock.withLock { defer { fired = true }; return !fired } }
}
