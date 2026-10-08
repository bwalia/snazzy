import AppKit
import Broadcast
import Foundation
import Observation
import SnazzyCore

/// Going live on YouTube, LinkedIn, Twitch, Vimeo, Facebook or any RTMP
/// server, to one or several at once. Stream keys are kept in the Keychain;
/// every start asks first, because this is the one time video leaves the Mac.
/// By default the same picture is also recorded to the Mac.
@MainActor @Observable
final class BroadcastController {
    /// The destination being set up in the UI (key, server).
    var platform: BroadcastPlatform {
        didSet { UserDefaults.standard.set(platform.rawValue, forKey: "SnazzyPro.broadcastPlatform") }
    }
    /// Where to stream when going live.
    var destinations: Set<BroadcastPlatform> {
        didSet { UserDefaults.standard.set(destinations.map(\.rawValue), forKey: "SnazzyPro.broadcastDestinations") }
    }
    var quality: BroadcastQuality = .hd1080
    /// Also record to this Mac while live.
    var recordWhileLive: Bool {
        didSet { UserDefaults.standard.set(recordWhileLive, forKey: "SnazzyPro.recordWhileLive") }
    }
    /// Server per platform (defaults to the platform's RTMPS ingest).
    var servers: [BroadcastPlatform: String] {
        didSet {
            let raw = Dictionary(uniqueKeysWithValues: servers.map { ($0.key.rawValue, $0.value) })
            UserDefaults.standard.set(raw, forKey: "SnazzyPro.broadcastServers")
        }
    }
    private(set) var states: [BroadcastPlatform: Broadcaster.State] = [:]
    private(set) var network: [BroadcastPlatform: Broadcaster.NetworkReport] = [:]
    private(set) var startedAt: Date?
    private(set) var savedKeys: Set<BroadcastPlatform> = []
    private(set) var message: String?

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var broadcasters: [BroadcastPlatform: Broadcaster] = [:]
    @ObservationIgnored private var refresher: Task<Void, Never>?
    @ObservationIgnored private var startedRecording = false
    /// Destinations that dropped while live and are waiting to reconnect.
    @ObservationIgnored private var retrying: [BroadcastPlatform: Task<Void, Never>] = [:]
    @ObservationIgnored private var attempts: [BroadcastPlatform: Int] = [:]
    static let maxReconnects = 3

    /// Roughly what each 1080p stream needs (video + audio + overhead).
    static let uploadNeeded: [String: Double] = ["1080p": 6, "720p": 3.5]

    init(app: AppModel) {
        self.app = app
        let d = UserDefaults.standard
        platform = BroadcastPlatform(rawValue: d.string(forKey: "SnazzyPro.broadcastPlatform") ?? "") ?? .youtube
        destinations = Set((d.stringArray(forKey: "SnazzyPro.broadcastDestinations") ?? ["youtube"]).compactMap(BroadcastPlatform.init(rawValue:)))
        recordWhileLive = d.object(forKey: "SnazzyPro.recordWhileLive") as? Bool ?? true
        let raw = d.dictionary(forKey: "SnazzyPro.broadcastServers") as? [String: String] ?? [:]
        servers = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in BroadcastPlatform(rawValue: k).map { ($0, v) } })
        refreshKeys()
    }

    var isActive: Bool { states.values.contains { $0 == .connecting || $0 == .live } }
    var liveDestinations: [BroadcastPlatform] { BroadcastPlatform.allCases.filter { states[$0] == .live } }
    /// The old single-state view (tools, remote status).
    var state: Broadcaster.State {
        if !liveDestinations.isEmpty { return .live }
        if states.values.contains(.connecting) { return .connecting }
        if let failed = states.values.first(where: { if case .failed = $0 { true } else { false } }) { return failed }
        return .idle
    }

    /// Destinations that are ready to go (selected, with a key and a server).
    var ready: [BroadcastPlatform] {
        BroadcastPlatform.allCases.filter { destinations.contains($0) && savedKeys.contains($0) && !server(for: $0).isEmpty }
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
        do {
            try app.secrets.setSecret(k, for: p.keychainAccount)
        } catch {
            message = "Couldn't save the \(p.displayName) stream key in the Keychain: \(error.localizedDescription)"
            return
        }
        destinations.insert(p)
        refreshKeys()
    }

    func deleteKey(for p: BroadcastPlatform) {
        try? app.secrets.deleteSecret(for: p.keychainAccount)
        destinations.remove(p)
        refreshKeys()
    }

    // MARK: Going live

    /// Asks first (this goes to the internet), then starts.
    func confirmAndStart() async {
        guard !isActive else { return }
        let targets = ready
        guard !targets.isEmpty else {
            message = "Choose where to stream and add its stream key first (\(platform.keyHelp))."
            return
        }
        let names = targets.map(\.displayName).joined(separator: " and ")
        let need = (Self.uploadNeeded[quality.name] ?? 6) * Double(targets.count)
        let alert = NSAlert()
        alert.messageText = "Go live on \(names)?"
        alert.informativeText = """
            This is the one time your video leaves your Mac. Snazzy Pro will send your live picture (\(sourceDescription), with your camera inset) and your microphone to \(names) using your stream key\(targets.count > 1 ? "s" : "").

            Who can watch depends on your settings there. On YouTube, “Unlisted” isn't private: anyone with the link can watch. For a private group, use a live room on your Wi-Fi instead.

            Viewers see you about 2–5 seconds late. \(quality.name) needs about \(Int(need.rounded())) Mbps of steady upload\(targets.count > 1 ? " for \(targets.count) destinations" : ""); if yours is lower, Snazzy Pro lowers the quality automatically.\(recordWhileLive ? " A copy is also recorded to this Mac." : "")
            """
        alert.addButton(withTitle: "Go Live")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        await start(targets)
    }

    private var sourceDescription: String {
        switch app.capture.setup.source {
        case .slides?: "your slides"
        case .window(_, let a, _)?: "the \(a) window"
        default: "your screen"
        }
    }

    func start(_ targets: [BroadcastPlatform]? = nil) async {
        guard !isActive else { return }
        let targets = targets ?? ready
        guard !targets.isEmpty else { return }
        message = nil
        network = [:]
        states = [:]
        if app.capture.setup.source == .slides, app.builder.isDeckOpen, app.builder.stage == nil { app.builder.openPopOut() }
        app.capture.restoreInsetFeed()
        app.capture.useScreen("broadcast", true)
        refresher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                for b in self.broadcasters.values { self.update(b) }
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for p in targets { group.addTask { await self.connect(p) } }
        }
        if !liveDestinations.isEmpty {
            startedAt = Date()
            if recordWhileLive, !app.capture.recorder.isActive {
                do {
                    try await app.capture.startRecording(countdown: 0)
                    startedRecording = true
                } catch {
                    message = "Live, but the recording didn't start: \(error.localizedDescription)"
                }
            }
            app.chat.logSession("broadcast_started", ["destinations": .array(liveDestinations.map { .string($0.rawValue) }), "quality": .string(quality.name)])
        } else {
            finish()
        }
    }

    func stop() async {
        let all = Array(broadcasters.values)
        for b in all { await b.stop() }
        if startedRecording {
            startedRecording = false
            await app.capture.stopRecording()
        }
        finish()
        app.chat.logSession("broadcast_stopped", [:])
    }

    /// Connects one destination; failures arrive through `stateChanged`.
    private func connect(_ p: BroadcastPlatform) async {
        guard let key = (try? app.secrets.secret(for: p.keychainAccount)) ?? nil, !key.isEmpty else {
            return stateChanged(.failed("\(p.displayName): no stream key."), for: p)
        }
        let server = server(for: p)
        guard server.hasPrefix("rtmp://") || server.hasPrefix("rtmps://") else {
            return stateChanged(.failed("\(p.displayName): the server address must start with rtmps:// (or rtmp://)."), for: p)
        }
        let b = Broadcaster()
        b.onState = { [weak self, weak b] s in
            // Ignore a broadcaster that was stopped or replaced meanwhile.
            guard let self, let b, self.broadcasters[p] === b else { return }
            self.stateChanged(s, for: p)
        }
        b.onNetwork = { [weak self] r in self?.network[p] = r }
        update(b)
        broadcasters[p] = b
        try? await b.start(server: server, key: key, quality: quality, micID: app.capture.setup.mic?.uniqueID)
        // Stopped while it was connecting: don't leave it streaming on its own.
        if broadcasters[p] !== b { await b.stop() }
    }

    private func stateChanged(_ s: Broadcaster.State, for p: BroadcastPlatform) {
        states[p] = s
        switch s {
        case .live:
            if attempts[p] != nil { attempts[p] = nil; message = nil }
        case .failed:
            broadcasters[p] = nil
            // A first connect that fails (wrong key or server) isn't retried.
            guard startedAt != nil else { return }
            if (attempts[p] ?? 0) < Self.maxReconnects { reconnect(p); return }
            guard broadcasters.isEmpty, retrying.isEmpty else { return }
            // Every destination is gone for good. Keep the copy on this Mac recording:
            // it's the safety net for exactly this.
            message = startedRecording ? "The stream ended, but the recording on this Mac continues. Stop it when you're done." : nil
            startedRecording = false
            finish()
            app.chat.logSession("broadcast_stopped", ["reason": "connection lost"])
        default:
            break
        }
    }

    /// Tries a dropped destination again after 2, 4, then 6 seconds.
    private func reconnect(_ p: BroadcastPlatform) {
        let attempt = (attempts[p] ?? 0) + 1
        attempts[p] = attempt
        states[p] = .connecting
        message = "\(p.displayName) dropped. Reconnecting (try \(attempt) of \(Self.maxReconnects))…"
        retrying[p] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2 * attempt)) } catch { return }
            guard let self else { return }
            self.retrying[p] = nil
            await self.connect(p)
        }
    }

    private func finish() {
        refresher?.cancel()
        refresher = nil
        for task in retrying.values { task.cancel() }
        retrying = [:]
        attempts = [:]
        broadcasters = [:]
        startedAt = nil
        network = [:]
        app.capture.useScreen("broadcast", false)
        for (p, s) in states where s == .live || s == .connecting { states[p] = .idle }
    }

    private func update(_ b: Broadcaster) {
        let capture = app.capture
        b.setSource(screen: capture.screenSource == nil ? nil : capture.screen.receiver,
                    camera: capture.insetFeed?.receiver, spec: capture.compositeSpec)
    }

    /// A warning when the upload can't keep up (shown while live).
    var uploadWarning: String? {
        guard let slow = network.first(where: { $0.value.insufficient }) else { return nil }
        let mbps = Double(slow.value.videoBitrate) / 1_000_000
        return "Your upload can't keep up, so the quality was lowered to \(String(format: "%.1f", mbps)) Mbps\(destinations.count > 1 ? ". Try fewer destinations or 720p." : ". Try 720p.")"
    }

    var uploadSummary: String? {
        guard !network.isEmpty else { return nil }
        let total = network.values.reduce(0) { $0 + $1.uploadBitsPerSecond }
        return String(format: "Uploading %.1f Mbps", Double(total) / 1_000_000)
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
            "live_on": .array(liveDestinations.map { .string($0.displayName) }),
            "destinations": .array(BroadcastPlatform.allCases.filter { destinations.contains($0) }.map { .string($0.displayName) }),
            "ready": .array(ready.map { .string($0.displayName) }),
            "quality": .string(quality.name),
            "record_while_live": .bool(recordWhileLive),
            "live_seconds": startedAt.map { .number(Date().timeIntervalSince($0).rounded()) } ?? .null,
            "upload": uploadSummary.map(JSONValue.string) ?? .null,
            "warning": uploadWarning.map(JSONValue.string) ?? .null,
        ]
    }
}
