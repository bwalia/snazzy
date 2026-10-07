import AppKit
import Broadcast
import Foundation
import Observation
import SnazzyCore

/// Going live on YouTube, Twitch, Vimeo, Facebook or any RTMP server.
/// Stream keys are kept in the Keychain; every start asks first, because
/// this sends the live picture and mic to the internet.
@MainActor @Observable
final class BroadcastController {
    var platform: BroadcastPlatform {
        didSet { UserDefaults.standard.set(platform.rawValue, forKey: "SnazzyPro.broadcastPlatform") }
    }
    var quality: BroadcastQuality = .hd1080
    /// Server per platform (defaults to the platform's RTMPS ingest).
    var servers: [BroadcastPlatform: String] {
        didSet {
            let raw = Dictionary(uniqueKeysWithValues: servers.map { ($0.key.rawValue, $0.value) })
            UserDefaults.standard.set(raw, forKey: "SnazzyPro.broadcastServers")
        }
    }
    private(set) var state: Broadcaster.State = .idle
    private(set) var startedAt: Date?
    private(set) var savedKeys: Set<BroadcastPlatform> = []

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var broadcaster: Broadcaster?
    @ObservationIgnored private var refresher: Task<Void, Never>?

    init(app: AppModel) {
        self.app = app
        platform = BroadcastPlatform(rawValue: UserDefaults.standard.string(forKey: "SnazzyPro.broadcastPlatform") ?? "") ?? .youtube
        let raw = UserDefaults.standard.dictionary(forKey: "SnazzyPro.broadcastServers") as? [String: String] ?? [:]
        servers = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in BroadcastPlatform(rawValue: k).map { ($0, v) } })
        refreshKeys()
    }

    var isActive: Bool {
        switch state {
        case .connecting, .live: true
        default: false
        }
    }

    func server(for p: BroadcastPlatform) -> String {
        let s = servers[p]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? p.defaultServer : s
    }

    // MARK: Stream keys (Keychain)

    func refreshKeys() {
        savedKeys = Set(BroadcastPlatform.allCases.filter { ((try? app.secrets.secret(for: $0.keychainAccount)) ?? nil)?.isEmpty == false })
    }

    func saveKey(_ key: String, for p: BroadcastPlatform) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        try? app.secrets.setSecret(k, for: p.keychainAccount)
        refreshKeys()
    }

    func deleteKey(for p: BroadcastPlatform) {
        try? app.secrets.deleteSecret(for: p.keychainAccount)
        refreshKeys()
    }

    // MARK: Going live

    /// Asks first (this goes to the internet), then starts.
    func confirmAndStart() async {
        guard !isActive else { return }
        guard savedKeys.contains(platform) else {
            state = .failed("Add your \(platform.displayName) stream key first (\(platform.keyHelp)).")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Go live on \(platform.displayName)?"
        alert.informativeText = """
            Snazzy Pro will send your live picture (\(sourceDescription), with your camera inset) and your microphone to \(platform == .custom ? server(for: platform) : platform.displayName) using your stream key.

            Who can watch depends on your \(platform == .custom ? "server" : platform.displayName) settings (public, unlisted or private). Stop any time with End Stream.
            """
        alert.addButton(withTitle: "Go Live")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        await start()
    }

    private var sourceDescription: String {
        switch app.capture.setup.source {
        case .slides?: "your slides"
        case .window(_, let a, _)?: "the \(a) window"
        default: "your screen"
        }
    }

    func start() async {
        guard !isActive, let key = (try? app.secrets.secret(for: platform.keychainAccount)) ?? nil, !key.isEmpty else { return }
        let server = server(for: platform)
        guard server.hasPrefix("rtmp://") || server.hasPrefix("rtmps://") else {
            state = .failed("The server address must start with rtmps:// (or rtmp://).")
            return
        }
        if app.capture.setup.source == .slides, app.builder.isDeckOpen, app.builder.stage == nil { app.builder.openPopOut() }
        app.capture.restoreInsetFeed()
        app.capture.useScreen("broadcast", true)
        let b = Broadcaster()
        b.onState = { [weak self] s in self?.stateChanged(s) }
        update(b)
        broadcaster = b
        refresher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, let b = self.broadcaster else { continue }
                self.update(b)
            }
        }
        do {
            try await b.start(server: server, key: key, quality: quality, micID: app.capture.setup.mic?.uniqueID)
            app.chat.logSession("broadcast_started", ["platform": .string(platform.rawValue), "quality": .string(quality.name)])
        } catch {
            cleanUp()
        }
    }

    func stop() async {
        guard let b = broadcaster else { return }
        await b.stop()
        cleanUp()
        app.chat.logSession("broadcast_stopped", ["platform": .string(platform.rawValue)])
    }

    private func stateChanged(_ s: Broadcaster.State) {
        state = s
        if s == .live, startedAt == nil { startedAt = Date() }
        if case .failed = s { cleanUp(keepState: true) }
    }

    private func cleanUp(keepState: Bool = true) {
        refresher?.cancel()
        refresher = nil
        broadcaster = nil
        startedAt = nil
        app.capture.useScreen("broadcast", false)
        if !keepState { state = .idle }
    }

    private func update(_ b: Broadcaster) {
        let capture = app.capture
        b.setSource(screen: capture.screenSource == nil ? nil : capture.screen.receiver,
                    camera: capture.insetFeed?.receiver, spec: capture.compositeSpec)
    }

    func stateJSON() -> JSONValue {
        let s: String = switch state {
        case .idle: "idle"
        case .connecting: "connecting"
        case .live: "live"
        case .failed(let m): "failed: \(m)"
        }
        return [
            "state": .string(s),
            "platform": .string(platform.displayName),
            "quality": .string(quality.name),
            "has_stream_key": .bool(savedKeys.contains(platform)),
            "live_seconds": startedAt.map { .number(Date().timeIntervalSince($0).rounded()) } ?? .null,
        ]
    }
}
