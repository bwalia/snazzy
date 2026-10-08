import AppKit
import CaptureEngine
import CoreImage.CIFilterBuiltins
import Foundation
import Live
import Observation
import SnazzyCore

/// The live room on the local network: students join from a browser (QR code
/// or link + room code), watch the live picture and add ideas to the
/// brainstorm board. Off until the user starts it and agrees to what's shared.
@MainActor @Observable
final class LiveController {
    enum Quality: String, CaseIterable, Identifiable {
        case high = "High (1080p, sharp text)"
        case standard = "Standard (720p)"
        case low = "Low (480p, busy Wi-Fi)"
        case remote = "Remote (540p, 12 fps: VPN or far away)"
        var id: String { rawValue }
        var encoder: LiveEncoder.Quality {
            switch self {
            case .high: .high
            case .standard: .standard
            case .low: .low
            case .remote: .remote
            }
        }
    }

    private(set) var isRunning = false
    private(set) var isStreaming = false
    private(set) var isStarting = false
    /// How often the video had to be restarted (shown when > 0).
    private(set) var restarts = 0
    private(set) var viewers = 0
    private(set) var board = BrainstormBoard()
    private(set) var joinURL: URL?
    /// Every address students could use (Wi-Fi, VPN…).
    private(set) var addresses: [NetworkAddress] = []
    /// Which address the QR code and link use.
    var selectedAddress: String? {
        didSet { updateJoinURL() }
    }
    private(set) var code = ""
    private(set) var qrCode: NSImage?
    private(set) var error: String?
    /// Changing it while live restarts the video (viewers reconnect by themselves).
    var quality: Quality = .standard {
        didSet {
            guard isStreaming, quality != oldValue else { return }
            Task { await restartVideo(reason: "quality changed to \(quality.rawValue)", counted: false) }
        }
    }
    /// Whether the link and QR code use a VPN address, where bandwidth is often low.
    var joinsOverVPN: Bool { addresses.first { $0.ip == selectedAddress }?.isVPN ?? false }
    /// The board topic typed before the room starts.
    var pendingTopic = ""

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var server: LiveServer?
    @ObservationIgnored private var encoder: LiveEncoder?
    @ObservationIgnored private var refresher: Task<Void, Never>?

    static let ports: [UInt16] = [8787, 8788, 8789, 8790]

    init(app: AppModel) {
        self.app = app
    }

    // MARK: Start and stop

    /// Asks first, showing exactly what's shared, then starts.
    func confirmAndStart() async {
        let alert = NSAlert()
        alert.messageText = "Start a live room?"
        alert.informativeText = """
            People on your Wi-Fi or local network who have the room code (in the QR code) can:
            • watch what you'd record: your \(sourceDescription), with your camera inset
            • hear your microphone
            • post ideas and vote on the brainstorm board

            It goes directly from this Mac to their browsers. Nothing is sent over the internet and nothing is saved by Snazzy Pro except the board while the room is open.
            """
        alert.addButton(withTitle: "Start Live Room")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        await start()
    }

    private var sourceDescription: String {
        switch app.capture.setup.source {
        case .slides?: "slides"
        case .window(_, let a, _)?: "\(a) window"
        case .display(_, let n)?: "screen (\(n))"
        default: "screen"
        }
    }

    func start() async {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        error = nil
        var board = BrainstormBoard(topic: "")
        board.setTopic(pendingTopic)
        var started: LiveServer?
        for port in Self.ports {
            let s = LiveServer(port: port, board: board)
            do { try await s.start(); started = s; break } catch { continue }
        }
        guard let server = started else {
            error = "Couldn't open the live room (ports \(Self.ports.first!)–\(Self.ports.last!) are busy)."
            return
        }
        server.onBoardChange = { [weak self] b in Task { @MainActor in self?.board = b } }
        server.onViewersChange = { [weak self] n in Task { @MainActor in self?.viewers = n } }
        server.onState = { [weak self] message in Task { @MainActor in if let message { self?.error = "Live room: \(message)" } } }
        self.server = server
        self.board = server.currentBoard()
        code = server.code
        refreshAddresses()
        if joinURL == nil { error = "This Mac isn't on a network. Connect to Wi-Fi so students can join." }

        // The picture: same source as recording.
        if app.capture.setup.source == .slides, app.builder.isDeckOpen, app.builder.stage == nil { app.builder.openPopOut() }
        app.capture.restoreInsetFeed()
        app.capture.useScreen("live", true)
        let encoder = LiveEncoder()
        let segments = server.segments
        encoder.onInitSegment = { segments.setInit($0) }
        encoder.onSegment = { data, duration in segments.append(data, duration: duration) }
        encoder.onError = { [weak self] message in Task { @MainActor in self?.error = "Live video stopped: \(message)" } }
        updateSource(encoder)
        do {
            try encoder.start(micID: app.capture.setup.mic?.uniqueID, quality: quality.encoder)
            self.encoder = encoder
            isStreaming = true
        } catch {
            self.error = "Live video couldn't start: \(error.localizedDescription). The board still works."
        }
        isRunning = true
        publishStatus()
        // Follow source, camera and layout changes; restart the video if it stalls.
        refresher = Task { [weak self] in
            var lastSeq = -1, lastFrames = -1
            var stalledSince = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, let encoder = self.encoder, let server = self.server else { continue }
                self.updateSource(encoder)
                // Both new segments and new frames must keep coming (a stuck
                // hardware encoder can keep making segments of a frozen picture).
                let seq = server.segments.statusJSON()["segments"]?.arrayValue?.last?["seq"]?.intValue ?? -1
                let frames = encoder.framesEncoded
                if seq != lastSeq && frames != lastFrames {
                    lastSeq = seq
                    lastFrames = frames
                    stalledSince = Date()
                } else if Date().timeIntervalSince(stalledSince) > 5 {
                    lastFrames = -1
                    stalledSince = Date()
                    await self.restartVideo(reason: encoder.stats)
                }
            }
        }
        app.chat.logSession("live_room_started", ["viewers_max": .number(Double(LiveServer.maxViewers))])
    }

    /// Starts a fresh encoder (viewers' players pick up the new stream by themselves).
    private func restartVideo(reason: String, counted: Bool = true) async {
        guard let server, let old = encoder else { return }
        Log.app.error("Live video restarting: \(reason, privacy: .public)")
        encoder = nil
        await old.stop()
        let encoder = LiveEncoder()
        let segments = server.segments
        encoder.onInitSegment = { segments.setInit($0) }
        encoder.onSegment = { data, duration in segments.append(data, duration: duration) }
        encoder.onError = { [weak self] message in Task { @MainActor in self?.error = "Live video stopped: \(message)" } }
        updateSource(encoder)
        do {
            try encoder.start(micID: app.capture.setup.mic?.uniqueID, quality: quality.encoder)
            self.encoder = encoder
            if counted { restarts += 1 }
        } catch {
            self.error = "Live video couldn't restart: \(error.localizedDescription)"
            isStreaming = false
            publishStatus()
        }
    }

    func stop() {
        guard isRunning else { return }
        refresher?.cancel()
        refresher = nil
        let encoder = self.encoder
        self.encoder = nil
        Task { await encoder?.stop() }
        server?.setStatus(["live": false, "message": "The live room has ended. Thanks for joining!"])
        let server = self.server
        self.server = nil
        // Let the goodbye reach browsers before closing.
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            server?.stop()
        }
        app.capture.useScreen("live", false)
        isRunning = false
        isStreaming = false
        viewers = 0
        joinURL = nil
        qrCode = nil
        app.chat.logSession("live_room_stopped", ["ideas": .number(Double(board.notes.count))])
    }

    /// Re-reads this Mac's addresses (e.g. after a VPN connects).
    func refreshAddresses() {
        addresses = Self.networkAddresses()
        if selectedAddress == nil || !addresses.contains(where: { $0.ip == selectedAddress }) {
            selectedAddress = addresses.first?.ip
        } else {
            updateJoinURL()
        }
    }

    private func updateJoinURL() {
        guard let server, let ip = selectedAddress else {
            joinURL = nil
            qrCode = nil
            return
        }
        joinURL = URL(string: "http://\(ip):\(server.port)/?k=\(server.code)")
        qrCode = joinURL.flatMap { Self.qr($0.absoluteString) }
    }

    private func updateSource(_ encoder: LiveEncoder) {
        let capture = app.capture
        encoder.setSource(screen: capture.screenSource == nil ? nil : capture.screen.receiver,
                          camera: capture.insetFeed?.receiver, spec: capture.compositeSpec)
    }

    /// Tells viewers what's on (the current slide's title when presenting).
    func publishStatus() {
        guard let server else { return }
        var status: [String: JSONValue] = ["live": .bool(isStreaming)]
        if app.capture.setup.source == .slides, app.builder.isDeckOpen {
            let i = app.builder.currentSlide
            if app.builder.deckSlides.indices.contains(i) { status["slide"] = .string(app.builder.deckSlides[i].displayTitle) }
        }
        server.setStatus(.object(status))
    }

    // MARK: Board (host)

    func setTopic(_ topic: String) {
        pendingTopic = topic
        server?.updateBoard { $0.setTopic(topic) }
    }

    func setBoardOpen(_ open: Bool) { server?.updateBoard { $0.setOpen(open) } }
    func setHidden(_ id: String, _ hidden: Bool) { server?.updateBoard { $0.setHidden(id, hidden) } }
    func delete(_ id: String) { server?.updateBoard { $0.delete(id) } }
    func clearBoard() { server?.updateBoard { $0.clear() } }

    /// Adds an idea as the presenter (shown with a Presenter badge).
    func addIdea(_ text: String) { server?.updateBoard { $0.addFromHost(text) } }

    /// Shows a message to everyone above the board ("" clears it).
    func announce(_ text: String) { server?.updateBoard { $0.announce(text) } }

    /// Asks the assistant to build a deck from the ideas.
    func turnIdeasIntoDeck() {
        app.chat.send("Turn the ideas from the live brainstorm into a slide deck. Call get_brainstorm for the ideas, group them into themes (strongest ideas by votes first), then build a presentation: a title slide with the topic, one slide per theme, and a closing slide with next steps. Add short speaker notes to every slide.")
    }

    var encoderStats: String { encoder?.stats ?? "no encoder" }

    func brainstormJSON() -> JSONValue {
        [
            "live_room_open": .bool(isRunning),
            "topic": .string(board.topic),
            "board_open": .bool(board.isOpen),
            "announcement": .string(board.announcement),
            "ideas": .array(board.ranked.map { ["text": .string($0.text), "author": .string($0.author), "votes": .number(Double($0.votes))] }),
            "hidden_count": .number(Double(board.notes.filter(\.hidden).count)),
        ]
    }

    func stateJSON() -> JSONValue {
        [
            "running": .bool(isRunning),
            "streaming_video": .bool(isStreaming),
            "viewers": .number(Double(viewers)),
            "join_url": joinURL.map { .string($0.absoluteString) } ?? .null,
            "room_code": isRunning ? .string(code) : .null,
            "ideas": .number(Double(board.ranked.count)),
        ]
    }

    // MARK: Helpers

    /// One of this Mac's IPv4 addresses that other devices can reach.
    struct NetworkAddress: Hashable, Identifiable {
        let interface: String
        let ip: String
        var id: String { ip }
        /// Wi-Fi/Ethernet, or a VPN tunnel (WireGuard, Tailscale, IPsec…).
        var isVPN: Bool { !interface.hasPrefix("en") }
        var label: String { isVPN ? "VPN (\(interface))" : "Wi-Fi / Ethernet (\(interface))" }
    }

    /// Wi-Fi/Ethernet first, then VPN tunnels. Loopback, self-assigned and
    /// Internet Sharing bridges are left out.
    static func networkAddresses() -> [NetworkAddress] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var out: [NetworkAddress] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  (Int32(ifa.ifa_flags) & IFF_UP) != 0, (Int32(ifa.ifa_flags) & IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(decoding: host.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
            let name = String(cString: ifa.ifa_name)
            let usable = ["en", "utun", "wg", "ipsec", "ppp", "tun", "tap"].contains { name.hasPrefix($0) }
            guard usable, !ip.hasPrefix("169.254."), !out.contains(where: { $0.ip == ip }) else { continue }
            out.append(NetworkAddress(interface: name, ip: ip))
        }
        return out.sorted { ($0.isVPN ? 1 : 0, $0.interface) < ($1.isVPN ? 1 : 0, $1.interface) }
    }

    /// The main Wi-Fi/Ethernet address (or a VPN one if that's all there is).
    static func lanAddress() -> String? { networkAddresses().first?.ip }

    static func qr(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: image.extent.width / 2, height: image.extent.height / 2))
    }
}
