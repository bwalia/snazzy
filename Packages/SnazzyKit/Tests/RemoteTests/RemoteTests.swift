import Foundation
import Network
import Testing
@testable import Remote

/// Collects values from callbacks for tests.
final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ t: T) { lock.withLock { items.append(t) } }
    var all: [T] { lock.withLock { items } }
    func wait(_ seconds: Double = 5, until: @escaping ([T]) -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if until(all) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return until(all)
    }
}

@Suite struct RemoteProtocolTests {
    @Test func framesRoundTripAndSplit() throws {
        let messages: [RemoteMessage] = [
            .hello(deviceID: "d1", deviceName: "iPad", version: 2, pairing: true, proof: Data([1, 2])),
            .command(id: 7, .goToSlide(3)),
            .status(RemoteStatus(hostName: "Mac", recording: "recording", elapsed: 12.5, slideIndex: 2, slideCount: 6, notes: "Smile")),
        ]
        let data = try messages.map(RemoteFrame.encode).reduce(Data(), +)
        var reader = RemoteFrame.Reader()
        var out: [RemoteMessage] = []
        // Arrives in awkward pieces.
        for chunk in stride(from: 0, to: data.count, by: 5).map({ data[$0..<min($0 + 5, data.count)] }) {
            out += try reader.append(Data(chunk))
        }
        #expect(out == messages)
        var bad = RemoteFrame.Reader()
        #expect(throws: RemoteError.self) { _ = try bad.append(Data([0x7f, 0xff, 0xff, 0xff])) }
    }

    @Test func unknownMessagesAreSkipped() throws {
        // A newer app's message this version can't read doesn't break the link.
        let unknown = Data(#"{"somethingNew":{}}"#.utf8)
        var length = UInt32(unknown.count).bigEndian
        let data = Data(bytes: &length, count: 4) + unknown + (try RemoteFrame.encode(.command(id: 2, .prompter(.toggle))))
        var reader = RemoteFrame.Reader()
        #expect(try reader.append(data) == [.command(id: 2, .prompter(.toggle))])
    }

    @Test func prompterMovesAtReadingSpeed() throws {
        let words = PrompterState.words(in: "one two  three\nfour")
        #expect(words == 4)
        // 120 words a minute = 2 a second; 40 words take 20 seconds.
        let p = PrompterState(running: true, wordsPerMinute: 120, progress: 0.25)
        #expect(abs(p.progress(after: 5, words: 40) - 0.5) < 1e-9)
        #expect(p.progress(after: 600, words: 40) == 1)
        #expect(PrompterState(running: false, wordsPerMinute: 120, progress: 0.25).progress(after: 5, words: 40) == 0.25)
        #expect(p.progress(after: 5, words: 0) == 0.25)
        // Old Macs send no teleprompter; new statuses round-trip it.
        let old = try JSONDecoder().decode(RemoteStatus.self, from: JSONEncoder().encode(RemoteStatus(hostName: "Mac")))
        #expect(old.prompter == nil)
        var status = RemoteStatus(hostName: "Mac", prompter: p)
        status.notes = "hi"
        #expect(try JSONDecoder().decode(RemoteStatus.self, from: JSONEncoder().encode(status)) == status)
    }

    @Test func inviteURL() throws {
        let invite = PairingInvite(hostID: "H1", hostName: "Bal's Mac", secret: RemoteSecurity.newKey(), address: "192.168.1.9:50000")
        let back = try #require(PairingInvite(url: invite.url))
        #expect(back == invite)
        #expect(PairingInvite(url: URL(string: "snazzypro://pair?h=H1&s=short")!) == nil)
        #expect(PairingInvite(url: URL(string: "https://evil.example/pair?h=H1")!) == nil)
    }
}

@Suite(.serialized) struct RemoteLinkTests {
    func host(devices: [TrustedDevice] = []) async -> (RemoteHost, UInt16, Box<TrustedDevice>, Box<String>) {
        let host = RemoteHost(hostID: "host-\(UUID().uuidString.prefix(4))", hostName: "Test Mac", devices: devices)
        let paired = Box<TrustedDevice>()
        let commands = Box<String>()
        let ports = Box<UInt16>()
        host.onPaired = { paired.add($0) }
        host.onListening = { port, _ in if let port { ports.add(port) } }
        host.onCommand = { device, command in
            if case .prompter = command { return (true, nil) }
            if command == .ping { return (true, nil) }
            commands.add("\(device):\(command)")
            return command == .stopRecording ? (false, "Not recording.") : (true, nil)
        }
        return (host, 0, paired, commands)
    }

    /// A paired device holds a key the Mac accepts, but may only speak for
    /// itself: it can't pair new devices or take over another device's ID.
    @Test func pairedDeviceCantPairOthersOrImpersonate() async throws {
        let keyA = RemoteSecurity.newKey(), keyB = RemoteSecurity.newKey()
        let (host, _, paired, _) = await host(devices: [TrustedDevice(id: "A", name: "A", key: keyA),
                                                        TrustedDevice(id: "B", name: "B", key: keyB)])
        host.start()
        for _ in 0..<40 where host.listeningPort == nil { try await Task.sleep(for: .milliseconds(50)) }
        let port = try #require(host.listeningPort)

        /// Connects as device A (its TLS key) and returns the Mac's first reply to `hello`.
        func reply(to hello: RemoteMessage) async -> RemoteMessage? {
            let params = RemoteSecurity.parameters(keys: [(RemoteSecurity.deviceIdentity("A"), keyA)])
            let connection = NWConnection(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!), using: params)
            let link = RemoteLink(connection, queue: DispatchQueue(label: "test-device"))
            let replies = Box<RemoteMessage>()
            link.onState = { if $0 == .ready { link.send(hello) } }
            link.onMessage = { replies.add($0) }
            link.start()
            _ = await replies.wait { !$0.isEmpty }
            link.close()
            return replies.all.first
        }
        func hello(_ id: String, pairing: Bool, key: Data) -> RemoteMessage {
            .hello(deviceID: id, deviceName: id, version: RemoteProtocol.version, pairing: pairing,
                   proof: RemoteSecurity.proof(deviceID: id, key: key))
        }

        // Pairing is closed: A can't pair a new device, even with a valid TLS key.
        guard case .bye = await reply(to: hello("C", pairing: true, key: keyA)) else { Issue.record("pairing accepted"); return }
        // A can't claim to be B.
        guard case .bye = await reply(to: hello("B", pairing: false, key: keyA)) else { Issue.record("impersonation accepted"); return }
        // No proof at all (an older app) is refused too.
        guard case .bye = await reply(to: .hello(deviceID: "A", deviceName: "A", version: RemoteProtocol.version, pairing: false, proof: nil))
        else { Issue.record("missing proof accepted"); return }
        // A as itself is welcome.
        guard case .welcome = await reply(to: hello("A", pairing: false, key: keyA)) else { Issue.record("A refused"); return }
        #expect(paired.all.isEmpty)
        host.stop()
    }

    @Test func pairCommandStatusReconnectRevoke() async throws {
        let (host, _, paired, commands) = await host()
        let invite = host.openPairing(address: nil)
        for _ in 0..<40 where host.listeningPort == nil { try await Task.sleep(for: .milliseconds(50)) }
        let port = try #require(host.listeningPort)
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)

        // Pair.
        let client = RemoteClient(deviceID: "dev-1", deviceName: "Test iPad")
        let hosts = Box<PairedHost>(), states = Box<RemoteClient.State>(), statuses = Box<RemoteStatus>()
        client.onPaired = { hosts.add($0) }
        client.onState = { states.add($0) }
        client.onStatus = { statuses.add($0) }
        client.pair(invite, endpoint: endpoint)
        #expect(await hosts.wait { !$0.isEmpty })
        #expect(paired.all.first?.id == "dev-1" && paired.all.first?.key == hosts.all.first?.key)
        #expect(hosts.all.first?.key != invite.secret)

        // Commands and status.
        let r1 = await client.send(.nextSlide)
        #expect(r1.ok)
        let r2 = await client.send(.stopRecording)
        #expect(!r2.ok && r2.message == "Not recording.")
        #expect(commands.all == ["dev-1:nextSlide", "dev-1:stopRecording"])
        host.publish(RemoteStatus(hostName: "Test Mac", recording: "recording", slideIndex: 1, slideCount: 4, notes: "Hello"))
        #expect(await statuses.wait { $0.last?.notes == "Hello" })

        // The teleprompter and ping go through like any command.
        #expect(await client.send(.prompter(.seek(0.5))).ok)
        #expect(await client.ping())

        // The QR code works once: a second device with the same invite is refused.
        try await Task.sleep(for: .milliseconds(300))
        let intruder = RemoteClient(deviceID: "dev-2", deviceName: "Other")
        let intruderStates = Box<RemoteClient.State>()
        intruder.onState = { intruderStates.add($0) }
        intruder.pair(invite, endpoint: endpoint)
        #expect(await intruderStates.wait(8) { $0.contains { if case .disconnected = $0 { true } else { false } } })
        #expect(!intruderStates.all.contains { if case .connected = $0 { true } else { false } })
        intruder.disconnect()

        // Reconnect with the device key.
        client.disconnect()
        try await Task.sleep(for: .milliseconds(300))
        let again = RemoteClient(deviceID: "dev-1", deviceName: "Test iPad")
        let againStates = Box<RemoteClient.State>()
        again.onState = { againStates.add($0) }
        again.connect(to: try #require(hosts.all.first), endpoint: endpoint)
        #expect(await againStates.wait { $0.contains(.connected(hostName: "Test Mac")) })

        // Removing the device closes it and its key stops working.
        host.removeDevice("dev-1")
        // The Mac's reason reaches the device, as a deliberate end (no retrying).
        #expect(await againStates.wait { $0.contains(.ended("This device was removed on the Mac.")) })
        try await Task.sleep(for: .milliseconds(300))
        let revoked = RemoteClient(deviceID: "dev-1", deviceName: "Test iPad")
        let revokedStates = Box<RemoteClient.State>()
        revoked.onState = { revokedStates.add($0) }
        revoked.connect(to: try #require(hosts.all.first), endpoint: NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
        #expect(await revokedStates.wait(8) { $0.contains { if case .disconnected = $0 { true } else { false } } })
        #expect(!revokedStates.all.contains { if case .connected = $0 { true } else { false } })
        revoked.disconnect()
        host.stop()
    }
}

@Suite(.serialized) struct RemoteTimeoutTests {
    @Test func noAnswerTimesOutAndDisconnects() async throws {
        let host = RemoteHost(hostID: "h-\(UUID().uuidString.prefix(4))", hostName: "Slow Mac", devices: [])
        // A Mac that never answers (e.g. the link died without closing).
        host.onCommand = { _, _ in
            try? await Task.sleep(for: .seconds(30))
            return (true, nil)
        }
        let invite = host.openPairing(address: nil)
        for _ in 0..<40 where host.listeningPort == nil { try await Task.sleep(for: .milliseconds(50)) }
        let port = try #require(host.listeningPort)
        let client = RemoteClient(deviceID: "d-slow", deviceName: "iPhone")
        let states = Box<RemoteClient.State>()
        client.onState = { states.add($0) }
        client.pair(invite, endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
        #expect(await states.wait { $0.contains { if case .connected = $0 { true } else { false } } })
        let started = Date()
        let r = await client.send(.nextSlide, timeout: 1)
        #expect(!r.ok && Date().timeIntervalSince(started) < 5)
        // The app is told, so it reconnects.
        #expect(await states.wait { $0.last.map { if case .disconnected = $0 { true } else { false } } ?? false })
        #expect(await client.send(.nextSlide).message == "Not connected.")
        host.stop()
    }

    @Test func recordingCommandsWaitLonger() {
        #expect(RemoteClient.timeout(for: .startRecording) > RemoteClient.timeout(for: .nextSlide))
        #expect(RemoteClient.timeout(for: .stopRecording) >= 30)
    }
}

@Suite struct WatchLinkTests {
    @Test func stateIsTrimmedAndRoundTrips() throws {
        let status = RemoteStatus(hostName: "Mac", recording: "recording", elapsed: 30, micLevel: 0.7, slideIndex: 1, slideCount: 5, notes: "Long notes")
        let state = WatchState(problem: nil, status: status, sentAt: Date(timeIntervalSince1970: 1000))
        #expect(state.status?.notes == nil)
        var moving = status
        moving.prompter = PrompterState(running: true, progress: 0.4)
        let a = WatchState(problem: nil, status: moving)
        moving.prompter?.progress = 0.6
        // Scrolling doesn't count as a change for the watch; pausing does.
        #expect(a.matches(WatchState(problem: nil, status: moving)))
        moving.prompter?.running = false
        #expect(!a.matches(WatchState(problem: nil, status: moving)))
        #expect(state.status?.micLevel == 0)
        let back = try #require(WatchLink.decode(WatchState.self, WatchLink.encode(state)))
        #expect(back == state)
        #expect(WatchLink.decode(WatchState.self, "not data") == nil)
    }

    @Test func timerKeepsRunningOnlyWhileRecording() {
        let start = Date(timeIntervalSince1970: 1000)
        var recording = WatchState(problem: nil, status: RemoteStatus(recording: "recording", elapsed: 30), sentAt: start)
        #expect(recording.elapsed(at: start.addingTimeInterval(5)) == 35)
        recording.status?.recording = "paused"
        #expect(recording.elapsed(at: start.addingTimeInterval(5)) == 30)
        #expect(WatchState(problem: "Not connected", status: nil).elapsed() == 0)
    }

    @Test func matchesIgnoresOnlyTheTimer() {
        let a = WatchState(problem: nil, status: RemoteStatus(recording: "recording", elapsed: 30, slideIndex: 1, slideCount: 5), sentAt: Date())
        var b = WatchState(problem: nil, status: RemoteStatus(recording: "recording", elapsed: 31, slideIndex: 1, slideCount: 5), sentAt: Date().addingTimeInterval(1))
        #expect(a.matches(b))
        b.status?.slideIndex = 2
        #expect(!a.matches(b))
    }

    @Test func watchCannotChat() {
        #expect(WatchLink.allows(.nextSlide))
        #expect(WatchLink.allows(.stopRecording))
        #expect(!WatchLink.allows(.chat("hi")))
        #expect(!WatchLink.allows(.openPresentWindow))
        #expect(WatchLink.allows(.prompter(.toggle)))
    }
}

@Suite struct RemoteAddressTests {
    @Test func multipleAddresses() {
        #expect(RemoteClient.endpoints("192.168.1.9:5000, 10.8.0.2:5000").count == 2)
        #expect(RemoteClient.endpoints(nil).isEmpty)
        #expect(RemoteClient.merge("10.8.0.2:5000", "192.168.1.9:5000,10.8.0.2:5000") == "10.8.0.2:5000,192.168.1.9:5000")
        #expect(RemoteClient.merge(nil, "a:1") == "a:1")
    }

    @Test func fallsBackToTheNextAddress() async throws {
        let host = RemoteHost(hostID: "h-\(UUID().uuidString.prefix(4))", hostName: "VPN Mac", devices: [])
        let invite0 = host.openPairing(address: nil)
        for _ in 0..<40 where host.listeningPort == nil { try await Task.sleep(for: .milliseconds(50)) }
        let port = try #require(host.listeningPort)
        // First address refuses (nothing listens there); the second works.
        var invite = invite0
        invite.address = "127.0.0.1:1,127.0.0.1:\(port)"
        let client = RemoteClient(deviceID: "d-vpn", deviceName: "iPad")
        let hosts = Box<PairedHost>()
        client.onPaired = { hosts.add($0) }
        client.pair(invite, endpoint: nil)
        #expect(await hosts.wait(10) { !$0.isEmpty })
        #expect(hosts.all.first?.address?.hasPrefix("127.0.0.1:\(port)") == true)
        client.disconnect()
        host.stop()
    }
}
