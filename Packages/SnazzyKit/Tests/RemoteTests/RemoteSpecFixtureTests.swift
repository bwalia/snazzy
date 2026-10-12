import Foundation
import Testing
@testable import Remote

/// Remote-protocol fixtures for `docs/specs/remote.md` (see BuilderTests/SpecFixtureTests.swift).
/// `SNAZZY_WRITE_FIXTURES=1` rewrites them; otherwise they must still match.
@Suite(.serialized) struct RemoteSpecFixtureTests {
    static let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "docs/specs/fixtures", directoryHint: .isDirectory)
    static var writing: Bool { ProcessInfo.processInfo.environment["SNAZZY_WRITE_FIXTURES"] == "1" }

    static func check(_ name: String, _ data: Data, sourceLocation: SourceLocation = #_sourceLocation) {
        let url = directory.appending(path: name)
        if writing {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            #expect(throws: Never.self, sourceLocation: sourceLocation) { try data.write(to: url) }
            return
        }
        #expect((try? Data(contentsOf: url)) == data, "docs/specs/fixtures/\(name) is out of date: run SNAZZY_WRITE_FIXTURES=1 swift test",
                sourceLocation: sourceLocation)
    }

    static let sorted: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static func pretty<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(value) + Data("\n".utf8)
    }

    /// A frame as `RemoteFrame.encode` makes it, with sorted keys so the fixture is
    /// stable (Swift's JSONEncoder doesn't promise a key order; readers don't care).
    static func frame(_ json: Data) -> Data {
        var length = UInt32(json.count).bigEndian
        return Data(bytes: &length, count: 4) + json
    }

    static let fullStatus = RemoteStatus(
        hostName: "Studio Mac", recording: "recording", countdown: 3, elapsed: 125.5, micLevel: 0.42, source: "Slides", deckName: "Q3 review",
        slideIndex: 2, slideCount: 12, slideTitle: "Revenue", nextSlideTitle: "Costs / margins", notes: "Mention the café \"partnership\".\nThen pause.",
        liveRoomViewers: 7, broadcast: "YouTube, Twitch", warnings: ["Low disk space", "Camera stalled"],
        prompter: PrompterState(running: true, wordsPerMinute: 160, progress: 0.25, script: "Line one\nLine two", visible: true))

    static let key = Data((0..<32).map { UInt8($0) })

    static let messages: [(String, RemoteMessage)] = {
        let commands: [(String, RemoteCommand)] = [
            ("startRecording", .startRecording), ("pauseRecording", .pauseRecording), ("resumeRecording", .resumeRecording),
            ("stopRecording", .stopRecording), ("nextSlide", .nextSlide), ("previousSlide", .previousSlide), ("goToSlide", .goToSlide(4)),
            ("openPresentWindow", .openPresentWindow), ("chat", .chat("Make a deck about \"Q3\" / results 📈")),
            ("prompter.play", .prompter(.play)), ("prompter.pause", .prompter(.pause)), ("prompter.toggle", .prompter(.toggle)),
            ("prompter.faster", .prompter(.faster)), ("prompter.slower", .prompter(.slower)), ("prompter.restart", .prompter(.restart)),
            ("prompter.seek", .prompter(.seek(0.5))), ("ping", .ping),
        ]
        return [
            ("hello.pairing", .hello(deviceID: "dev-1234", deviceName: "Ada's iPhone", version: RemoteProtocol.version, pairing: true,
                                     proof: RemoteSecurity.proof(deviceID: "dev-1234", key: key))),
            ("hello.old", .hello(deviceID: "dev-old", deviceName: "Old iPad", version: 1, pairing: false, proof: nil)),
            ("paired", .paired(hostID: "host-abc", hostName: "Studio Mac", deviceKey: key)),
            ("welcome", .welcome(hostID: "host-abc", hostName: "Studio Mac")),
            ("status.full", .status(fullStatus)),
            ("status.minimal", .status(RemoteStatus())),
            ("result.ok", .result(id: 7, ok: true, message: nil)),
            ("result.error", .result(id: 8, ok: false, message: "Nothing is recording.")),
            ("chatReply", .chatReply("Done: 6 slides.")),
            ("bye", .bye("This device was removed on the Mac.")),
        ] + commands.enumerated().map { i, c in ("command.\(c.0)", .command(id: i + 1, c.1)) }
    }()

    struct MessageCase: Codable {
        var name: String
        var json: String
        var watchAllows: Bool?
    }

    struct ProofCase: Codable {
        var deviceID: String
        var key: String
        var proof: String
    }

    struct PairingCase: Codable {
        var url: String
        var hostID: String?
        var hostName: String?
        var secret: String?
        var address: String?
    }

    struct InviteCase: Codable {
        var hostID: String
        var hostName: String
        var secret: String
        var address: String?
        var url: String
    }

    @Test func remoteFixtures() throws {
        var cases: [MessageCase] = []
        var stream = Data()
        for (name, message) in Self.messages {
            let json = try Self.sorted.encode(message)
            // Same bytes as the app's own framing, apart from key order.
            #expect(try RemoteFrame.encode(message).count == Self.frame(json).count)
            var allows: Bool?
            if case .command(_, let c) = message { allows = WatchLink.allows(c) }
            cases.append(MessageCase(name: name, json: String(decoding: json, as: UTF8.self), watchAllows: allows))
            stream += Self.frame(json)
            if name == "status.full" {
                // Something from a newer version: skipped, the link stays up.
                stream += Self.frame(Data(#"{"somethingNew":{"x":1}}"#.utf8))
            }
        }
        // The stream decodes to every message, in order, skipping the unknown one.
        var reader = RemoteFrame.Reader()
        var decoded: [RemoteMessage] = []
        for chunk in stride(from: 0, to: stream.count, by: 97) {
            decoded += try reader.append(stream.subdata(in: chunk..<min(stream.count, chunk + 97)))
        }
        #expect(decoded == Self.messages.map(\.1))
        Self.check("remote-frames.bin", stream)
        Self.check("remote-status.json", try Self.pretty(Self.fullStatus))

        let proofs = [("dev-1234", Self.key), ("", Data(repeating: 0xAB, count: 32)), ("Ünïcode-device 📱", Data("short key".utf8)),
                      ("x", Data(repeating: 7, count: 100))].map { id, key in
            ProofCase(deviceID: id, key: key.base64EncodedString(), proof: RemoteSecurity.proof(deviceID: id, key: key).base64EncodedString())
        }
        for p in proofs {
            #expect(RemoteSecurity.verify(Data(base64Encoded: p.proof), deviceID: p.deviceID, key: Data(base64Encoded: p.key)!))
        }

        let secret = Data((0..<32).map { UInt8(255 - $0) })
        let invites = [PairingInvite(hostID: "host-abc", hostName: "Studio Mac", secret: secret, address: nil),
                       PairingInvite(hostID: "E3B0C442-98FC-1C14", hostName: "Ada's MacBook Pro (2) & co", secret: secret, address: "192.168.1.20:52000,10.8.0.2:52000"),
                       PairingInvite(hostID: "h", hostName: "Café 東京 +=?/#%", secret: Data(repeating: 0xFB, count: 32), address: "[fe80::1]:5000")]
            .map { InviteCase(hostID: $0.hostID, hostName: $0.hostName, secret: $0.secret.base64EncodedString(), address: $0.address, url: $0.url.absoluteString) }
        let good = secret.base64URL
        let urls = invites.map(\.url) + [
            "snazzypro://pair?h=host&s=\(good)",
            "snazzypro://pair?v=2&h=host&n=My%20Mac&s=\(good)&a=10.0.0.2:5000&extra=1",
            "snazzypro://pair?h=first&h=second&s=\(good)",
            "snazzypro://pair?n=Mac&s=\(good)",
            "snazzypro://pair?h=&s=\(good)",
            "snazzypro://pair?h=host&s=\(Data(repeating: 1, count: 31).base64URL)",
            "snazzypro://pair?h=host&s=\(Data(repeating: 1, count: 33).base64URL)",
            "snazzypro://pair?h=host&s=not*base64",
            "snazzypro://pair?h=host",
            "snazzypro://other?h=host&s=\(good)",
            "https://pair?h=host&s=\(good)",
            "SNAZZYPRO://pair?h=host&s=\(good)",
            "snazzypro://PAIR?h=host&s=\(good)",
            "snazzypro://pair/?h=host&s=\(good)",
            "snazzypro://pair?h=a+b&n=a+b&s=\(good)",
            "snazzypro://pair?h=%E6%9D%B1&s=\(secret.base64EncodedString())",
        ]
        let pairing = urls.map { s -> PairingCase in
            guard let url = URL(string: s), let p = PairingInvite(url: url) else { return PairingCase(url: s) }
            return PairingCase(url: s, hostID: p.hostID, hostName: p.hostName, secret: p.secret.base64EncodedString(), address: p.address)
        }

        struct Out: Codable {
            var version: Int
            var serviceType: String
            var maxFrame: Int
            var pairingIdentity: String
            var deviceIdentity: String
            var messages: [MessageCase]
            var unknown: [String]
            var proofs: [ProofCase]
            var invites: [InviteCase]
            var pairing: [PairingCase]
        }
        Self.check("remote-cases.json", try Self.pretty(Out(
            version: RemoteProtocol.version, serviceType: RemoteProtocol.serviceType, maxFrame: RemoteProtocol.maxFrame,
            pairingIdentity: RemoteSecurity.pairingIdentity(hostID: "host-abc"), deviceIdentity: RemoteSecurity.deviceIdentity("dev-1234"),
            messages: cases, unknown: [#"{"somethingNew":{"x":1}}"#], proofs: proofs, invites: invites, pairing: pairing)))
    }

    @Test func oversizedFrameIsRefused() {
        var reader = RemoteFrame.Reader()
        var length = UInt32(RemoteProtocol.maxFrame + 1).bigEndian
        #expect(throws: RemoteError.self) { try reader.append(Data(bytes: &length, count: 4)) }
    }
}
