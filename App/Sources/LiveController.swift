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
        case standard = "Standard (720p)"
        case low = "Low (480p, busy Wi-Fi)"
        var id: String { rawValue }
        var encoder: LiveEncoder.Quality { self == .standard ? .standard : .low }
    }

    private(set) var isRunning = false
    private(set) var isStreaming = false
    private(set) var isStarting = false
    private(set) var viewers = 0
    private(set) var board = BrainstormBoard()
    private(set) var joinURL: URL?
    private(set) var code = ""
    private(set) var qrCode: NSImage?
    private(set) var error: String?
    var quality: Quality = .standard
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
        joinURL = Self.lanAddress().flatMap { URL(string: "http://\($0):\(server.port)/?k=\(server.code)") }
        qrCode = joinURL.flatMap { Self.qr($0.absoluteString) }
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
        // Follow source, camera and layout changes.
        refresher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, let encoder = self.encoder else { continue }
                self.updateSource(encoder)
            }
        }
        app.chat.logSession("live_room_started", ["viewers_max": .number(Double(LiveServer.maxViewers))])
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

    /// This Mac's IPv4 address on Wi-Fi or Ethernet (not loopback or self-assigned).
    static func lanAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var candidates: [(name: String, ip: String)] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  (Int32(ifa.ifa_flags) & IFF_UP) != 0, (Int32(ifa.ifa_flags) & IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(decoding: host.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
            let name = String(cString: ifa.ifa_name)
            guard !ip.hasPrefix("169.254."), name.hasPrefix("en") else { continue }
            candidates.append((name, ip))
        }
        return candidates.sorted { $0.name < $1.name }.first?.ip
    }

    static func qr(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: image.extent.width / 2, height: image.extent.height / 2))
    }
}
