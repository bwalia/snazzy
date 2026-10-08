import Foundation
import Network
import Observation
import Remote
import SnazzyCore
import UIKit

/// The device side: paired Macs (keys in the Keychain), finding them on the
/// network, connecting, and the Mac's live status.
@MainActor @Observable
final class RemoteModel {
    enum Connection: Equatable {
        case idle
        case searching
        case connecting(String)
        case connected(String)
        case failed(String)
    }

    private(set) var hosts: [PairedHost] = []
    private(set) var connection: Connection = .idle { didSet { updateWatch() } }
    private(set) var status: RemoteStatus? { didSet { updateWatch() } }
    private(set) var lastResult: String?
    private(set) var chat: [(id: UUID, fromMe: Bool, text: String)] = []
    private(set) var busy = false

    @ObservationIgnored private let secrets: any SecretStore = KeychainStore()
    @ObservationIgnored private var client: RemoteClient?
    @ObservationIgnored private let browser = RemoteBrowser()
    @ObservationIgnored private var found: [RemoteBrowser.Found] = []
    @ObservationIgnored private var currentHostID: String?
    @ObservationIgnored private var retry: Task<Void, Never>?
    /// The Apple Watch app, which controls the Mac through this app.
    @ObservationIgnored private let watch = WatchRelay()

    static let hostsAccount = "remote.hosts"
    #if DEBUG
    private static var didDebugPair = false
    #endif

    var deviceID: String {
        if let id = UserDefaults.standard.string(forKey: "remote.deviceID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "remote.deviceID")
        return id
    }

    var isConnected: Bool { if case .connected = connection { true } else { false } }

    init() {
        hosts = loadHosts()
        browser.onChange = { [weak self] found in Task { @MainActor in self?.found(found) } }
        watch.perform = { [weak self] command in
            guard let self else { return (false, "Snazzy Pro isn't running on your iPhone.") }
            return await self.perform(command)
        }
        watch.current = { [weak self] in self?.watchState ?? WatchState(problem: "Open Snazzy Pro on your iPhone.", status: nil) }
    }

    func start() {
        #if DEBUG
        // Tests: `simctl launch … -debugPairURL snazzypro://pair?...`
        if !Self.didDebugPair, let s = UserDefaults.standard.string(forKey: "debugPairURL"), let url = URL(string: s) {
            Self.didDebugPair = true
            pair(with: url)
            return
        }
        #endif
        browser.start()
        if !hosts.isEmpty, !isConnected { connection = .searching }
        connectToKnownHost()
    }

    // MARK: Pairing

    /// From a scanned QR code or a snazzypro:// link.
    func pair(with url: URL) {
        guard let invite = PairingInvite(url: url) else {
            connection = .failed("That isn't a Snazzy Pro pairing code.")
            return
        }
        let endpoint = found.first { $0.hostID == invite.hostID }?.endpoint
        let c = makeClient()
        connection = .connecting(invite.hostName)
        currentHostID = invite.hostID
        c.pair(invite, endpoint: endpoint)
    }

    func forget(_ host: PairedHost) {
        hosts.removeAll { $0.id == host.id }
        saveHosts()
        if currentHostID == host.id { disconnect() }
    }

    // MARK: Connecting

    private func found(_ list: [RemoteBrowser.Found]) {
        found = list
        connectToKnownHost()
    }

    private func connectToKnownHost() {
        guard !isConnected else { return }
        if case .connecting = connection { return }
        // A paired Mac that Bonjour can see, else the last address of the first one.
        let match = hosts.lazy.compactMap { h in self.found.first { $0.hostID == h.id }.map { (h, Optional($0.endpoint)) } }.first
        guard let (host, endpoint) = match ?? hosts.first.map({ ($0, nil) }) else { return }
        let c = makeClient()
        currentHostID = host.id
        connection = .connecting(host.name)
        c.connect(to: host, endpoint: endpoint)
    }

    func reconnect() {
        disconnect()
        connection = .searching
        connectToKnownHost()
    }

    func disconnect() {
        retry?.cancel()
        client?.disconnect()
        client = nil
        status = nil
        connection = .idle
    }

    private func makeClient() -> RemoteClient {
        client?.disconnect()
        let c = RemoteClient(deviceID: deviceID, deviceName: UIDevice.current.name)
        c.onState = { [weak self] s in Task { @MainActor in self?.stateChanged(s) } }
        c.onStatus = { [weak self] s in Task { @MainActor in self?.status = s } }
        c.onChatReply = { [weak self] text in Task { @MainActor in self?.chat.append((UUID(), false, text)) } }
        c.onPaired = { [weak self] host in Task { @MainActor in self?.paired(host) } }
        client = c
        return c
    }

    private func paired(_ host: PairedHost) {
        hosts.removeAll { $0.id == host.id }
        hosts.insert(host, at: 0)
        saveHosts()
    }

    private func stateChanged(_ s: RemoteClient.State) {
        switch s {
        case .connecting:
            break
        case .connected(let name):
            connection = .connected(name)
            UIApplication.shared.isIdleTimerDisabled = true
            // Remember the address that worked.
            if let id = currentHostID, let i = hosts.firstIndex(where: { $0.id == id }), hosts[i].name != name {
                hosts[i].name = name
                saveHosts()
            }
        case .disconnected(let reason):
            UIApplication.shared.isIdleTimerDisabled = false
            status = nil
            client = nil
            connection = .failed(reason ?? "Disconnected.")
            // Try again shortly while the app is open.
            retry?.cancel()
            retry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, let self, !self.hosts.isEmpty, !self.isConnected else { return }
                self.connectToKnownHost()
            }
        }
    }

    // MARK: Commands

    func send(_ command: RemoteCommand) {
        guard client != nil else { return }
        busy = true
        Task {
            let (ok, message) = await perform(command)
            busy = false
            lastResult = ok ? nil : (message ?? "That didn't work.")
            if ok { UIImpactFeedbackGenerator(style: .medium).impactOccurred() } else { UINotificationFeedbackGenerator().notificationOccurred(.error) }
        }
    }

    /// Runs a command on the Mac and returns its answer.
    func perform(_ command: RemoteCommand) async -> (ok: Bool, message: String?) {
        guard let client else { return (false, "Your iPhone isn't connected to a Mac.") }
        return await client.send(command)
    }

    // MARK: Apple Watch

    private var watchState: WatchState {
        let problem: String? = switch connection {
        case .connected: status == nil ? "Waiting for the Mac…" : nil
        case .connecting(let name): "Connecting to \(name)…"
        case .searching: "Looking for your Mac…"
        case .failed(let reason): reason
        case .idle: hosts.isEmpty ? "Pair your iPhone with your Mac first." : "Not connected to your Mac."
        }
        return WatchState(problem: problem, status: status)
    }

    private func updateWatch() { watch.publish(watchState) }

    func ask(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        chat.append((UUID(), true, t))
        send(.chat(t))
    }

    // MARK: Keychain

    private func loadHosts() -> [PairedHost] {
        guard let s = (try? secrets.secret(for: Self.hostsAccount)) ?? nil, let data = Data(base64Encoded: s) else { return [] }
        return (try? JSONDecoder().decode([PairedHost].self, from: data)) ?? []
    }

    private func saveHosts() {
        if hosts.isEmpty {
            try? secrets.deleteSecret(for: Self.hostsAccount)
        } else if let data = try? JSONEncoder().encode(hosts) {
            try? secrets.setSecret(data.base64EncodedString(), for: Self.hostsAccount)
        }
    }
}
