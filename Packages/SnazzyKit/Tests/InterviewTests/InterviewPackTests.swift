import CryptoKit
import Foundation
import Testing
import SnazzyCore
@testable import Interview

@Suite struct InterviewPackTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("packtest-\(UUID().uuidString)", isDirectory: true)

    init() throws { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }

    func file(_ name: String, _ data: Data) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func random(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8.random(in: 0...255) }) }

    @Test func encryptsAndDecryptsAnySize() throws {
        let key = SymmetricKey(size: .bits256)
        for size in [0, 1, 64, 65, 128, 1000] {
            let plain = random(size)
            let input = try file("in-\(size)", plain), sealed = dir.appendingPathComponent("s-\(size)"), back = dir.appendingPathComponent("b-\(size)")
            try PackCrypto.encrypt(input, to: sealed, key: key, chunkSize: 64)
            #expect(try Data(contentsOf: sealed) != plain || size == 0)
            try PackCrypto.decrypt(sealed, to: back, key: key)
            #expect(try Data(contentsOf: back) == plain, "size \(size)")
        }
    }

    @Test func refusesTamperingTruncationAndTheWrongKey() throws {
        let key = SymmetricKey(size: .bits256)
        let input = try file("in", random(300)), sealed = dir.appendingPathComponent("s"), out = dir.appendingPathComponent("o")
        try PackCrypto.encrypt(input, to: sealed, key: key, chunkSize: 64)
        let good = try Data(contentsOf: sealed)
        #expect(throws: (any Error).self) { try PackCrypto.decrypt(sealed, to: out, key: SymmetricKey(size: .bits256)) }
        var flipped = good; flipped[40] ^= 1
        try flipped.write(to: sealed)
        #expect(throws: (any Error).self) { try PackCrypto.decrypt(sealed, to: out, key: key) }
        // Drop the last chunk: the one before it wasn't sealed as the last.
        try good.prefix(16 + 4 * 80).write(to: sealed)
        #expect(throws: (any Error).self) { try PackCrypto.decrypt(sealed, to: out, key: key) }
        // Swap two chunks.
        let c1 = good.subdata(in: 16..<96), c2 = good.subdata(in: 96..<176)
        try (good.prefix(16) + c2 + c1 + good.dropFirst(176)).write(to: sealed)
        #expect(throws: (any Error).self) { try PackCrypto.decrypt(sealed, to: out, key: key) }
    }

    @Test func packsRoundTripWithAnIntroDeck() throws {
        var kit = try sampleKit()
        kit.approvedAt = Date(timeIntervalSince1970: 1_792_000_000)
        kit.approvedBy = "Recruiter"
        let intro = dir.appendingPathComponent("intro-src", isDirectory: true)
        try FileManager.default.createDirectory(at: intro.appendingPathComponent("media"), withIntermediateDirectories: true)
        try Data("<section class=\"slide\">Hello</section>".utf8).write(to: intro.appendingPathComponent("index.html"))
        let video = random(200_000)
        try video.write(to: intro.appendingPathComponent("media/welcome.mp4"))
        let sealed = try InterviewPack.build(kit: kit, intro: intro, in: dir.appendingPathComponent("build"))
        #expect(sealed.size > 200_000)
        let opened = try InterviewPack.open(sealed.file, keyBase64: sealed.keyBase64, sha256: sealed.sha256, into: dir.appendingPathComponent("open"))
        #expect(opened.manifest.kit == kit)
        #expect(try Data(contentsOf: opened.introFolder!.appendingPathComponent("media/welcome.mp4")) == video)
        #expect(throws: (any Error).self) {
            try InterviewPack.open(sealed.file, keyBase64: sealed.keyBase64, sha256: String(repeating: "0", count: 64), into: dir.appendingPathComponent("x"))
        }
        kit.approvedAt = nil
        #expect(throws: (any Error).self) { try InterviewPack.build(kit: kit, in: dir.appendingPathComponent("b2")) }
    }

    @Test func parsesInviteLinks() {
        let web = "https://hire.example.com/i/ITRjmUlkH8vG04JpgGeaCegQbas48ayr8oyOo9TZSn0"
        #expect(InviteLink(web) == InviteLink(web))
        #expect(InviteLink(web)?.token == "ITRjmUlkH8vG04JpgGeaCegQbas48ayr8oyOo9TZSn0")
        #expect(InviteLink(web)?.api.absoluteString == "https://hire.example.com")
        let app = "snazzypro://interview?link=" + web.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! + "&api=https%3A%2F%2Fapi.example.com"
        #expect(InviteLink(app)?.api.absoluteString == "https://api.example.com")
        #expect(InviteLink(app)?.token == InviteLink(web)?.token)
        #expect(InviteLink(web + "?api=https%3A%2F%2Fapi.example.com")?.api.absoluteString == "https://api.example.com")
        #expect(InviteLink(web + "?api=http%3A%2F%2Fapi.example.com") == nil)  // answers must travel encrypted
        #expect(InviteLink("http://hire.example.com/i/ITRjmUlkH8vG04JpgGeaCegQbas48ayr8oyOo9TZSn0") == nil)  // not encrypted
        #expect(InviteLink("https://hire.example.com/i/short") == nil)
        #expect(InviteLink("https://hire.example.com/i/abc%2F..%2Fxxxxxxxxxxxxxxxxxxxxxxx") == nil)
        #expect(InviteLink("not a link") == nil)
    }

    @Test func parsesInviteeLists() {
        let list = OpsAPILink.Invitee.parse("""
        Name,Email
        Priya Shah, priya@example.com
        "Sam Lee" <sam@example.com>
        jo@example.com
        Alex Doe\talex@example.com

        """)
        #expect(list == [.init(name: "Priya Shah", email: "priya@example.com"), .init(name: "Sam Lee", email: "sam@example.com"),
                         .init(name: "jo", email: "jo@example.com"), .init(name: "Alex Doe", email: "alex@example.com")])
    }

    @Test func candidateViewKeepsSlidesInStep() throws {
        let kit = try sampleKit()
        let q2 = kit.questions[1].id
        let json = """
        {"state":"in_progress","role_title":"T","notice":"n","notice_hash":"h","choices":null,"seconds_left":812.4,"has_pack":true,
         "turns":[{"id":"t1","role":"interviewer","text":"Hello","kind":"opening"},
                  {"id":"t2","role":"interviewer","text":"Q2","kind":"core","question_id":"\(q2)"},
                  {"id":"t3","role":"candidate","text":"A","kind":"answer"}]}
        """
        let v = try InterviewJSON.decoder.decode(CandidateView.self, from: Data(json.utf8))
        #expect(v.secondsLeft == 812 && v.hasPack == true && !v.isFinished)
        #expect(v.slideIndex(for: kit) == 2 + (kit.eligibility.isEmpty ? 0 : 1) + 1)
    }
}
