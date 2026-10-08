import AppKit
import Assistant
import Foundation
import Observation
import Remote
import SnazzyCore

/// Remote control from the Snazzy Pro iPhone/iPad app: pairing (QR code),
/// paired devices (keys in the Keychain), commands and status updates.
@MainActor @Observable
final class RemoteController {
    private(set) var devices: [TrustedDevice] = []
    private(set) var connected: [String] = []
    private(set) var pairingURL: URL?
    private(set) var pairingQR: NSImage?
    private(set) var pairingExpires: Date?
    private(set) var error: String?

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var host: RemoteHost?
    @ObservationIgnored private var publisher: Task<Void, Never>?
    @ObservationIgnored private var pairingTimer: Task<Void, Never>?

    static let devicesAccount = "remote.devices"

    init(app: AppModel) {
        self.app = app
        devices = loadDevices()
        if !devices.isEmpty { startHost() }
    }

    var hostID: String {
        if let id = UserDefaults.standard.string(forKey: "SnazzyPro.remoteHostID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "SnazzyPro.remoteHostID")
        return id
    }

    var hostName: String { Host.current().localizedName ?? "Mac" }

    // MARK: Host

    private func startHost() {
        guard host == nil else { return }
        let h = RemoteHost(hostID: hostID, hostName: hostName, devices: devices)
        h.onPaired = { [weak self] device in Task { @MainActor in self?.paired(device) } }
        h.onConnected = { [weak self] names in Task { @MainActor in self?.connected = names } }
        h.onListening = { [weak self] _, error in Task { @MainActor in self?.error = error.map { "Remote control: \($0)" } } }
        h.onCommand = { [weak self] deviceID, command in
            guard let self else { return (false, "Not available.") }
            return await self.run(command, from: deviceID)
        }
        h.start()
        host = h
        publisher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                self.host?.publish(self.status())
            }
        }
    }

    // MARK: Pairing

    /// Shows a QR code for 3 minutes; one device can pair with it.
    func openPairing() async {
        startHost()
        guard let host else { return }
        _ = host.openPairing(address: nil)
        // The QR code includes this Mac's address once the port is open.
        var port: UInt16?
        for _ in 0..<40 {
            port = host.listeningPort
            if port != nil { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        // Every address (Wi-Fi first, then VPN such as WireGuard): Bonjour
        // doesn't cross VPNs, so the device tries these in turn.
        let address = port.flatMap { p -> String? in
            let all = LiveController.networkAddresses().map { "\($0.ip):\(p)" }
            return all.isEmpty ? nil : all.joined(separator: ",")
        }
        let invite = host.openPairing(address: address)
        pairingURL = invite.url
        pairingQR = LiveController.qr(invite.url.absoluteString)
        pairingExpires = Date().addingTimeInterval(180)
        pairingTimer?.cancel()
        pairingTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled else { return }
            self?.closePairing()
        }
    }

    func closePairing() {
        pairingTimer?.cancel()
        host?.closePairing()
        pairingURL = nil
        pairingQR = nil
        pairingExpires = nil
    }

    private func paired(_ device: TrustedDevice) {
        devices.removeAll { $0.id == device.id }
        devices.append(device)
        saveDevices()
        pairingTimer?.cancel()
        pairingURL = nil
        pairingQR = nil
        pairingExpires = nil
        app.chat.logSession("remote_paired", ["device": .string(device.name)])
    }

    func remove(_ device: TrustedDevice) {
        host?.removeDevice(device.id)
        devices.removeAll { $0.id == device.id }
        saveDevices()
    }

    // MARK: Keychain

    /// The stored list couldn't be read: saving now would replace it with only the new devices.
    @ObservationIgnored private var devicesUnreadable = false

    private func loadDevices() -> [TrustedDevice] {
        let stored: String?
        do {
            stored = try app.secrets.secret(for: Self.devicesAccount)
        } catch {
            devicesUnreadable = true
            self.error = "Couldn't read your paired devices from the Keychain (\(error.localizedDescription)). Pairing changes won't be saved until Snazzy Pro can read them."
            return []
        }
        guard let stored, let data = Data(base64Encoded: stored) else { return [] }
        return (try? JSONDecoder().decode([TrustedDevice].self, from: data)) ?? []
    }

    private func saveDevices() {
        guard !devicesUnreadable else { return }
        if devices.isEmpty {
            try? app.secrets.deleteSecret(for: Self.devicesAccount)
        } else if let data = try? JSONEncoder().encode(devices) {
            try? app.secrets.setSecret(data.base64EncodedString(), for: Self.devicesAccount)
        }
    }

    // MARK: Commands

    private func run(_ command: RemoteCommand, from deviceID: String) async -> (Bool, String?) {
        let capture = app.capture
        let builder = app.builder
        switch command {
        case .startRecording:
            guard !capture.recorder.isActive else { return (false, "Already recording.") }
            do {
                try await capture.startRecording()
                return (true, nil)
            } catch {
                return (false, error.localizedDescription)
            }
        case .pauseRecording:
            guard capture.recorder.state == .recording else { return (false, "Not recording.") }
            capture.pauseRecording()
            return (true, nil)
        case .resumeRecording:
            guard capture.recorder.state == .paused else { return (false, "Not paused.") }
            capture.resumeRecording()
            return (true, nil)
        case .stopRecording:
            guard capture.recorder.isActive else { return (false, "Not recording.") }
            let result = await capture.stopRecording()
            return (result != nil, result.map { "Saved \($0.composite.lastPathComponent)" } ?? "Nothing was saved.")
        case .nextSlide:
            guard builder.isDeckOpen else { return (false, "No deck is open.") }
            builder.nextSlide()
            return (true, nil)
        case .previousSlide:
            guard builder.isDeckOpen else { return (false, "No deck is open.") }
            builder.previousSlide()
            return (true, nil)
        case .goToSlide(let i):
            guard builder.isDeckOpen else { return (false, "No deck is open.") }
            builder.goToSlide(i)
            return (true, nil)
        case .openPresentWindow:
            guard builder.isDeckOpen else { return (false, "No deck is open.") }
            builder.openPopOut()
            return (true, nil)
        case .chat(let text):
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return (false, "Empty message.") }
            guard app.chat.send(clean) else { return (false, "The assistant is busy.") }
            let host = self.host
            Task { @MainActor [weak self] in
                // Wait for the reply, then send its final text to the device.
                for _ in 0..<600 {
                    try? await Task.sleep(for: .milliseconds(500))
                    if self?.app.chat.isRunning == false { break }
                }
                guard let self else { return }
                let reply = self.app.chat.conversation.messages.last { $0.role == .assistant }?.text ?? ""
                host?.sendChatReply(reply.isEmpty ? "Done." : reply, to: deviceID)
            }
            return (true, nil)
        }
    }

    // MARK: Status

    private func status() -> RemoteStatus {
        let capture = app.capture
        let recorder = capture.recorder
        let builder = app.builder
        var s = RemoteStatus(hostName: hostName)
        switch recorder.state {
        case .idle: s.recording = "idle"
        case .countdown(let n): s.recording = "countdown"; s.countdown = n
        case .recording: s.recording = "recording"
        case .paused: s.recording = "paused"
        case .finishing: s.recording = "finishing"
        case .failed(let m): s.recording = "failed"; s.warnings.append(m)
        }
        s.elapsed = (recorder.elapsed * 10).rounded() / 10
        s.micLevel = (recorder.micLevel * 20).rounded() / 20
        switch capture.setup.source {
        case .slides?: s.source = "Slides"
        case .display(_, let n)?: s.source = "Display: \(n)"
        case .window(_, let a, _)?: s.source = "Window: \(a)"
        default: s.source = "Nothing selected"
        }
        if builder.isDeckOpen {
            let i = builder.currentSlide
            s.deckName = builder.current?.name
            s.slideIndex = i
            s.slideCount = builder.deckSlides.count
            if builder.deckSlides.indices.contains(i) {
                s.slideTitle = builder.deckSlides[i].displayTitle
                s.notes = builder.deckSlides[i].notes.isEmpty ? nil : builder.deckSlides[i].notes
            }
            if builder.deckSlides.indices.contains(i + 1) { s.nextSlideTitle = builder.deckSlides[i + 1].displayTitle }
        }
        if app.live.isRunning { s.liveRoomViewers = app.live.viewers }
        if !app.broadcast.liveDestinations.isEmpty { s.broadcast = app.broadcast.liveDestinations.map(\.displayName).joined(separator: " + ") }
        if let w = recorder.warning { s.warnings.append(w) }
        return s
    }

    func stateJSON() -> JSONValue {
        [
            "paired_devices": .array(devices.map { .string($0.name) }),
            "connected": .array(connected.map { .string($0) }),
            "pairing_open": .bool(pairingURL != nil),
        ]
    }
}
