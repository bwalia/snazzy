import Foundation
import Network
import Testing
@testable import Live
import SnazzyCore

@Suite struct BrainstormBoardTests {
    @Test func postVoteModerate() throws {
        var board = BrainstormBoard(topic: "Field trip ideas")
        let t0 = Date(timeIntervalSince1970: 1000)
        let a = try board.add(text: "  Science\nmuseum  ", author: "Ana", poster: "p1", now: t0)
        #expect(a.text == "Science museum" && a.author == "Ana")
        let b = try board.add(text: "Zoo", author: "", poster: "p2", now: t0)
        #expect(b.author == "Anonymous")
        #expect(throws: BrainstormBoard.BoardError.tooFast) { try board.add(text: "Again", author: "Ana", poster: "p1", now: t0.addingTimeInterval(1)) }
        try board.add(text: "Again", author: "Ana", poster: "p1", now: t0.addingTimeInterval(5))
        #expect(throws: BrainstormBoard.BoardError.empty) { try board.add(text: " \n ", author: "x", poster: "p3", now: t0) }
        #expect(throws: BrainstormBoard.BoardError.tooLong) { try board.add(text: String(repeating: "a", count: 281), author: "x", poster: "p3", now: t0) }

        #expect(try board.vote(b.id, voter: "v1"))
        #expect(try board.vote(b.id, voter: "v2"))
        #expect(try !board.vote(b.id, voter: "v2"))  // toggles off
        #expect(board.ranked.first?.id == b.id)

        let json = board.publicJSON(for: "v1")
        #expect(json["notes"]?.arrayValue?.first?["voted"] == .bool(true))
        #expect(json["notes"]?.arrayValue?.first?["voters"] == nil)

        board.setHidden(a.id, true)
        #expect(board.ranked.count == 2)
        #expect(throws: BrainstormBoard.BoardError.unknownNote) { try board.vote(a.id, voter: "v1") }
        board.setOpen(false)
        #expect(throws: BrainstormBoard.BoardError.closed) { try board.add(text: "Late", author: "", poster: "p9") }
        #expect(board.summaryText.hasPrefix("Topic: Field trip ideas\n- Zoo (1 vote"))
    }

    @Test func perPersonLimit() throws {
        var board = BrainstormBoard()
        for i in 0..<BrainstormBoard.maxNotesPerPerson {
            try board.add(text: "Idea \(i)", author: "", poster: "flood", now: Date(timeIntervalSince1970: Double(i) * 10))
        }
        #expect(throws: BrainstormBoard.BoardError.full) { try board.add(text: "One more", author: "", poster: "flood", now: Date(timeIntervalSince1970: 99_999)) }
    }
}

@Suite struct LiveSegmentsTests {
    @Test func playlistAndWindow() {
        let s = LiveSegments(window: 3)
        #expect(s.playlist(query: "k=A") == nil)
        var initData = Data("....ftyp....avcC".utf8) + Data([1, 0x64, 0x00, 0x28]) + Data("....mp4a".utf8)
        s.setInit(initData)
        for i in 0..<5 { s.append(Data([UInt8(i)]), duration: 1.0) }
        let list = s.playlist(query: "k=A")!
        #expect(list.contains("#EXT-X-MEDIA-SEQUENCE:2"))
        #expect(list.contains("#EXT-X-MAP:URI=\"init.mp4?k=A\""))
        #expect(list.contains("seg-4.m4s?k=A") && !list.contains("seg-1.m4s"))
        #expect(s.segment(1) == nil && s.segment(4)?.data == Data([4]))
        #expect(s.statusJSON()["codecs"] == "avc1.640028,mp4a.40.2")
        initData = Data("avcC".utf8) + Data([1, 0x4d, 0x40, 0x1f])
        s.setInit(initData)
        #expect(s.statusJSON()["codecs"] == "avc1.4d401f")
        #expect(s.statusJSON()["generation"] == 2)
    }
}

@Suite struct LiveServerTests {
    /// A request from a device on the network (by IP address).
    func call(_ server: LiveServer, _ method: String, _ path: String, body: String = "", from device: String = "10.0.0.1",
              client: String = "c1") -> HTTPResponse {
        server.handle(HTTPRequest(method: method, path: path, headers: ["x-snazzy-client": client], body: Data(body.utf8)), from: device)
    }

    @Test func roomCodeAndRoutes() throws {
        let server = LiveServer(port: 0, code: "ABC234")
        #expect(call(server, "GET", "/").status == 200)
        #expect(call(server, "GET", "/api/board").status == 401)
        #expect(call(server, "GET", "/api/board?k=WRONG1").status == 401)
        #expect(call(server, "GET", "/api/board?k=abc234").status == 200)  // case-insensitive
        #expect(call(server, "GET", "/live/stream.m3u8?k=ABC234").status == 404)  // not live yet

        let posted = call(server, "POST", "/api/notes?k=ABC234", body: #"{"text":"<script>alert(1)</script>","name":"Bo"}"#)
        #expect(posted.status == 200)
        let board = try JSONValue.parse(posted.body)
        let note = try #require(board["notes"]?.arrayValue?.first)
        #expect(note["text"] == "<script>alert(1)</script>")  // stored as text; the page inserts it with textContent
        let again = call(server, "POST", "/api/notes?k=ABC234", body: #"{"text":"second"}"#)
        #expect(again.status == 429)
        let id = note["id"]?.stringValue ?? ""
        let voted = call(server, "POST", "/api/vote?k=ABC234", body: #"{"id":"\#(id)"}"#, from: "10.0.0.2")
        #expect(try JSONValue.parse(voted.body)["notes"]?.arrayValue?.first?["votes"] == 1)

        server.updateBoard { $0.setOpen(false) }
        #expect(call(server, "POST", "/api/notes?k=ABC234", body: #"{"text":"late"}"#, from: "10.0.0.3").status == 409)
        #expect(call(server, "GET", "/etc/passwd?k=ABC234").status == 404)
        let page = call(server, "GET", "/")
        #expect(page.extraHeaders["Content-Security-Policy"]?.contains("default-src 'self'") == true)
    }

    /// Limits count per device (IP address), so changing the browser ID or guessing
    /// codes from one device doesn't get around them.
    @Test func limitsArePerDevice() async throws {
        let server = LiveServer(port: 0, code: "ABC234")
        let posted = call(server, "POST", "/api/notes?k=ABC234", body: #"{"text":"idea"}"#, from: "10.0.0.9")
        let id = try JSONValue.parse(posted.body)["notes"]?.arrayValue?.first?["id"]?.stringValue ?? ""
        try await Task.sleep(for: .seconds(LiveServer.postInterval + 0.05))

        // A new browser ID from the same device is the same voter: the second vote toggles it off.
        let vote = #"{"id":"\#(id)"}"#
        #expect(call(server, "POST", "/api/vote?k=ABC234", body: vote, from: "10.0.0.5", client: "a").status == 200)
        #expect(call(server, "POST", "/api/vote?k=ABC234", body: vote, from: "10.0.0.5", client: "b").status == 429)  // too soon
        try await Task.sleep(for: .seconds(LiveServer.postInterval + 0.05))
        let again = call(server, "POST", "/api/vote?k=ABC234", body: vote, from: "10.0.0.5", client: "b")
        #expect(try JSONValue.parse(again.body)["notes"]?.arrayValue?.first?["votes"] == 0)

        // Guessing the code: after enough wrong tries the device has to wait, even with the right code.
        for _ in 0..<LiveServer.maxWrongCodes { _ = call(server, "GET", "/api/board?k=WRONG1", from: "10.0.0.66") }
        #expect(call(server, "GET", "/api/board?k=ABC234", from: "10.0.0.66").status == 429)
        #expect(call(server, "GET", "/api/board?k=ABC234", from: "10.0.0.7").status == 200)  // others unaffected
    }

    /// One device can't hold open more than its share of connections (a slow-request attack).
    @Test func oneDeviceCantHogConnections() async throws {
        let port = UInt16.random(in: 40_000...49_000)
        let server = LiveServer(port: port)
        try await server.start()
        defer { server.stop() }
        let refused = Counter()
        let queue = DispatchQueue(label: "test-clients")
        let extra = 5
        var clients: [NWConnection] = []
        for _ in 0..<(LiveServer.maxConnectionsPerDevice + extra) {
            let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            // Idle (no request sent): only the server closing it ends the read.
            c.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, done, error in if done || error != nil { refused.add() } }
            c.start(queue: queue)
            clients.append(c)
        }
        try await Task.sleep(for: .seconds(1))
        #expect(refused.value == extra)
        clients.forEach { $0.cancel() }
    }

    /// Video segments reuse one connection: over a distant VPN a new connection
    /// per segment took longer than the segment lasts, and the picture froze.
    @Test func connectionsStayOpenForTheNextRequest() async throws {
        let port = UInt16.random(in: 40_000...49_000)
        let server = LiveServer(port: port, code: "ABC234")
        try await server.start()
        defer { server.stop() }
        let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        c.start(queue: DispatchQueue(label: "test-keepalive"))
        defer { c.cancel() }
        for _ in 0..<3 {
            let reply = try await Self.exchange(c, "GET /api/board?k=ABC234 HTTP/1.1\r\nHost: x\r\n\r\n")
            #expect(reply.hasPrefix("HTTP/1.1 200") && reply.contains("Connection: keep-alive"))
        }
        let closing = try await Self.exchange(c, "GET /api/board?k=ABC234 HTTP/1.1\r\nConnection: close\r\n\r\n")
        #expect(closing.contains("Connection: close"))
        #expect(!LiveServer.keepsAlive(HTTPRequest(method: "GET", path: "/", headers: [:], body: Data()), HTTPResponse(status: 400, body: Data())))
    }

    /// Sends one request and reads one whole response (head plus Content-Length bytes).
    private static func exchange(_ c: NWConnection, _ request: String) async throws -> String {
        c.send(content: Data(request.utf8), completion: .idempotent)
        var data = Data()
        while true {
            let chunk: Data = try await withCheckedThrowingContinuation { cont in
                c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { d, _, done, error in
                    if let error { cont.resume(throwing: error) } else if let d, !d.isEmpty { cont.resume(returning: d) }
                    else { cont.resume(throwing: CancellationError()) }
                    _ = done
                }
            }
            data.append(chunk)
            let text = String(decoding: data, as: UTF8.self)
            if let end = text.range(of: "\r\n\r\n"),
               let line = text[..<end.lowerBound].split(separator: "\r\n").first(where: { $0.hasPrefix("Content-Length:") }),
               let length = Int(line.dropFirst("Content-Length:".count).trimmingCharacters(in: .whitespaces)),
               data.count >= text[..<end.upperBound].utf8.count + length {
                return text
            }
        }
    }

    @Test func codesAvoidLookAlikes() {
        for _ in 0..<50 {
            let c = LiveServer.makeCode()
            #expect(c.count == 6 && !c.contains(where: { "01ILO".contains($0) }))
        }
        #expect(LiveServer.constantTimeEqual("ABC", "ABC") && !LiveServer.constantTimeEqual("ABC", "ABD") && !LiveServer.constantTimeEqual("AB", "ABC"))
    }
}

@Suite struct LiveServerPortTests {
    @Test func busyPortThrows() async throws {
        let port = UInt16.random(in: 40_000...49_000)
        let first = LiveServer(port: port)
        try await first.start()
        defer { first.stop() }
        let second = LiveServer(port: port)
        await #expect(throws: (any Error).self) { try await second.start() }
    }
}

@Suite struct PresenterBoardTests {
    @Test func presenterIdeasAndAnnouncements() throws {
        var board = BrainstormBoard(topic: "Fair")
        board.setOpen(false)
        let added = board.addFromHost("  Start with a plan  ")
        let n = try #require(added)
        board.addFromHost("Second")  // no rate limit
        #expect(n.fromHost && n.author == "Presenter" && board.notes.count == 2)
        let empty = board.addFromHost("   ")
        #expect(empty == nil)
        board.announce("Five minutes left — vote now!")
        let json = board.publicJSON()
        #expect(json["announcement"] == "Five minutes left — vote now!")
        #expect(json["notes"]?.arrayValue?.first?["host"] == true)
        #expect(board.summaryText.contains("(0 votes, presenter)"))
    }
}

/// Counts callbacks from any queue.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}
