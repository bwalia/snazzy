import Foundation
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
    func req(_ method: String, _ path: String, body: String = "", client: String = "c1") -> HTTPRequest {
        HTTPRequest(method: method, path: path, headers: ["x-snazzy-client": client], body: Data(body.utf8))
    }

    @Test func roomCodeAndRoutes() throws {
        let server = LiveServer(port: 0, code: "ABC234")
        #expect(server.handle(req("GET", "/")).status == 200)
        #expect(server.handle(req("GET", "/api/board")).status == 401)
        #expect(server.handle(req("GET", "/api/board?k=WRONG1")).status == 401)
        #expect(server.handle(req("GET", "/api/board?k=abc234")).status == 200)  // case-insensitive
        #expect(server.handle(req("GET", "/live/stream.m3u8?k=ABC234")).status == 404)  // not live yet

        let posted = server.handle(req("POST", "/api/notes?k=ABC234", body: #"{"text":"<script>alert(1)</script>","name":"Bo"}"#))
        #expect(posted.status == 200)
        let board = try JSONValue.parse(posted.body)
        let note = try #require(board["notes"]?.arrayValue?.first)
        #expect(note["text"] == "<script>alert(1)</script>")  // stored as text; the page inserts it with textContent
        let again = server.handle(req("POST", "/api/notes?k=ABC234", body: #"{"text":"second"}"#))
        #expect(again.status == 429)
        let id = note["id"]?.stringValue ?? ""
        let voted = server.handle(req("POST", "/api/vote?k=ABC234", body: #"{"id":"\#(id)"}"#, client: "c2"))
        #expect(try JSONValue.parse(voted.body)["notes"]?.arrayValue?.first?["votes"] == 1)

        server.updateBoard { $0.setOpen(false) }
        #expect(server.handle(req("POST", "/api/notes?k=ABC234", body: #"{"text":"late"}"#, client: "c3")).status == 409)
        #expect(server.handle(req("GET", "/etc/passwd?k=ABC234")).status == 404)
        let page = server.handle(req("GET", "/"))
        #expect(page.extraHeaders["Content-Security-Policy"]?.contains("default-src 'self'") == true)
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
