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
    // Limits per device, keyed by its IP address on the network (which a page can't
    // choose, unlike anything it sends), so one device can't tie up or flood the room.
    static let maxConnectionsPerDevice = 24
    static let maxStreamsPerDevice = 3
    /// A request must arrive (and its answer go out) within this; event streams are exempt.
    static let requestTimeout: TimeInterval = 10
    static let postInterval: TimeInterval = 0.25
    /// Wrong room codes allowed per device per minute before it has to wait.
    static let maxWrongCodes = 30
    /// Board updates go out at most this often, however fast votes arrive.
    static let boardUpdateInterval: TimeInterval = 0.25

    private let queue = DispatchQueue(label: "com.snazzy.pro.live-server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var board: BrainstormBoard
    private var status: JSONValue = ["live": false]
    private var subscribers: [ObjectIdentifier: (connection: NWConnection, voter: String)] = [:]
    private var keepAlive: DispatchSourceTimer?
    private var openConnections: [String: Int] = [:]
    private var lastPost: [String: Date] = [:]
    private var wrongCodes: [String: [Date]] = [:]
    private var boardUpdatePending = false

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
        // The join link is an IPv4 address; IPv4 only also keeps a device to one address.
        (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
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
        let device = Self.address(of: connection)
        let allowed = lock.withLock { () -> Bool in
            guard openConnections[device, default: 0] < Self.maxConnectionsPerDevice else { return false }
            openConnections[device, default: 0] += 1
            return true
        }
        guard allowed else { return connection.cancel() }
        let id = ObjectIdentifier(connection)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed: connection.cancel()
            case .cancelled: self?.closed(id, device: device)
            default: break
            }
        }
        connection.start(queue: queue)
        // Slow or idle connections (a request trickling in) are dropped.
        queue.asyncAfter(deadline: .now() + Self.requestTimeout) { [weak self, weak connection] in
            guard let self, let connection, !self.lock.withLock({ self.subscribers[id] != nil }) else { return }
            connection.cancel()
        }
        receive(connection, buffer: Data(), device: device)
    }

    private func closed(_ id: ObjectIdentifier, device: String) {
        let (removed, n) = lock.withLock { () -> (Bool, Int) in
            openConnections[device, default: 1] -= 1
            if openConnections[device] == 0 { openConnections[device] = nil }
            return (subscribers.removeValue(forKey: id) != nil, subscribers.count)
        }
        if removed { onViewersChange?(n) }
    }

    /// The device's IP address, without the port.
    static func address(of connection: NWConnection) -> String {
        if case .hostPort(let host, _) = connection.endpoint { return "\(host)" }
        return "unknown"
    }

    private func receive(_ connection: NWConnection, buffer: Data, device: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequest.parse(buffer, maxBody: Self.maxBody) {
            case .complete(let request):
                self.respond(to: request, on: connection, device: device)
            case .incomplete where !isComplete && error == nil && buffer.count < Self.maxBody + 8_192:
                self.receive(connection, buffer: buffer, device: device)
            default:
                self.send(HTTPResponse(status: 400, body: Data("Bad request".utf8), contentType: "text/plain"), on: connection)
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection, device: String) {
        if request.method == "GET", request.route == "/api/events", codeProblem(request, from: device) == nil {
            subscribe(connection, device: device)
            return
        }
        send(handle(request, from: device), on: connection)
    }

    /// Routing (internal for tests); `device` is the caller's IP address. SSE is handled separately.
    func handle(_ request: HTTPRequest, from device: String) -> HTTPResponse {
        let route = request.route
        // The page itself works without a code (it asks for one).
        if request.method == "GET", route == "/" || route == "/index.html" {
            return HTTPResponse(status: 200, body: Data(LiveViewerPage.html.utf8), contentType: "text/html; charset=utf-8",
                                extraHeaders: Self.pageHeaders)
        }
        if request.method == "GET", route == "/favicon.ico" { return HTTPResponse(status: 204, body: Data()) }
        if let problem = codeProblem(request, from: device) { return problem }
        // One vote per idea and the post limits count per device, not per browser ID.
        let voter = device
        if request.method == "POST" {
            let now = Date()
            let tooSoon = lock.withLock { () -> Bool in
                defer { lastPost[device] = now }
                return lastPost[device].map { now.timeIntervalSince($0) < Self.postInterval } ?? false
            }
            if tooSoon { return json(429, ["error": "Slow down a little."]) }
        }
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

    /// Nil when the room code is right. A device that keeps guessing has to wait a minute.
    private func codeProblem(_ request: HTTPRequest, from device: String) -> HTTPResponse? {
        let now = Date()
        let guesses = lock.withLock { () -> Int in
            wrongCodes[device] = wrongCodes[device]?.filter { now.timeIntervalSince($0) < 60 }
            return wrongCodes[device]?.count ?? 0
        }
        guard guesses < Self.maxWrongCodes else { return json(429, ["error": "Too many wrong room codes. Wait a minute and try again."]) }
        let given = request.query["k"] ?? request.headers["x-room-code"] ?? ""
        if Self.constantTimeEqual(given.uppercased(), code) { return nil }
        lock.withLock { wrongCodes[device, default: []].append(now) }
        return json(401, ["error": "Wrong or missing room code."])
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

    private func subscribe(_ connection: NWConnection, device: String) {
        let voter = device
        let (count, mine) = lock.withLock { (subscribers.count, subscribers.values.filter { $0.voter == device }.count) }
        guard count < Self.maxViewers, mine < Self.maxStreamsPerDevice else {
            send(HTTPResponse(status: 503, body: Data(#"{"error":"The room is full."}"#.utf8)), on: connection)
            return
        }
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: keep-alive\r\nX-Accel-Buffering: no\r\n\r\nretry: 2000\n\n"
        let (b, s) = lock.withLock { (board.publicJSON(for: voter), status) }
        var first = Data(head.utf8)
        first.append(Self.event("board", b))
        first.append(Self.event("status", s))
        let id = ObjectIdentifier(connection)
        // Notice when the browser goes away (a read returns end of stream); cancelling
        // removes the subscriber (see `accept`).
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in connection.cancel() }
        let n = lock.withLock { () -> Int in
            subscribers[id] = (connection, voter)
            return subscribers.count
        }
        connection.send(content: first, completion: .contentProcessed { _ in })
        onViewersChange?(n)
    }

    static func event(_ name: String, _ value: JSONValue) -> Data {
        let json = (try? value.encoded(sortedKeys: false)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return Data("event: \(name)\ndata: \(json)\n\n".utf8)
    }

    /// Sends the board to everyone, batching changes that arrive close together.
    private func boardChanged(_ snapshot: BrainstormBoard) {
        let schedule = lock.withLock { () -> Bool in
            defer { boardUpdatePending = true }
            return !boardUpdatePending
        }
        guard schedule else { return }
        queue.asyncAfter(deadline: .now() + Self.boardUpdateInterval) { [weak self] in
            guard let self else { return }
            let board = self.lock.withLock { () -> BrainstormBoard in
                self.boardUpdatePending = false
                return self.board
            }
            self.broadcast(event: "board") { voter in board.publicJSON(for: voter) }
            self.onBoardChange?(board)
        }
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
