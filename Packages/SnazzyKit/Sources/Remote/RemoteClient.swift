import Foundation
import Network

/// A Mac that this device has paired with.
public struct PairedHost: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// This device's key for that Mac (keep it in the Keychain).
    public var key: Data
    /// Direct addresses ("ip:port", comma-separated, the last one that worked
    /// first), used when Bonjour can't find the Mac, e.g. over a VPN.
    public var address: String?

    public init(id: String, name: String, key: Data, address: String?) {
        self.id = id
        self.name = name
        self.key = key
        self.address = address
    }
}

/// Finds Macs running Snazzy Pro on the local network.
public final class RemoteBrowser: @unchecked Sendable {
    public struct Found: Sendable, Equatable, Identifiable {
        public var id: String { hostID }
        public let hostID: String
        public let name: String
        public let endpoint: NWEndpoint
    }

    public var onChange: (@Sendable ([Found]) -> Void)?
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.snazzy.pro.remote-browser")

    public init() {}

    public func start() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: RemoteProtocol.serviceType, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found: [Found] = results.compactMap { r in
                guard case .service(let name, _, _, _) = r.endpoint else { return nil }
                var hostID = name
                if case .bonjour(let txt) = r.metadata, let id = txt["id"] { hostID = id }
                return Found(hostID: hostID, name: name, endpoint: r.endpoint)
            }
            self?.onChange?(found)
        }
        b.start(queue: queue)
        browser = b
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }
}

/// The device side of the link: pairs, connects, sends commands, receives status.
public final class RemoteClient: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case disconnected(String?)
        case connecting
        case connected(hostName: String)
    }

    public let deviceID: String
    public let deviceName: String

    public var onState: (@Sendable (State) -> Void)?
    public var onStatus: (@Sendable (RemoteStatus) -> Void)?
    public var onChatReply: (@Sendable (String) -> Void)?
    /// Pairing finished: store the host (its key belongs in the Keychain).
    public var onPaired: (@Sendable (PairedHost) -> Void)?

    private let queue = DispatchQueue(label: "com.snazzy.pro.remote-client")
    private let lock = NSLock()
    private var link: RemoteLink?
    /// True between hello being answered and the link closing.
    private var isOpen = false
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<(Bool, String?), Never>] = [:]

    public init(deviceID: String, deviceName: String) {
        self.deviceID = deviceID
        self.deviceName = deviceName
    }

    /// Pairs using a scanned invite. `endpoint` comes from Bonjour, or the
    /// invite's address is used.
    public func pair(_ invite: PairingInvite, endpoint: NWEndpoint?) {
        let candidates = ([endpoint].compactMap { $0 }) + Self.endpoints(invite.address)
        guard !candidates.isEmpty else {
            onState?(.disconnected("Couldn't find that Mac on this network."))
            return
        }
        connect(candidates: candidates, identity: RemoteSecurity.pairingIdentity(hostID: invite.hostID), key: invite.secret,
                pairing: true, addresses: invite.address)
    }

    /// Connects to a Mac paired before.
    public func connect(to host: PairedHost, endpoint: NWEndpoint?) {
        let candidates = ([endpoint].compactMap { $0 }) + Self.endpoints(host.address)
        guard !candidates.isEmpty else {
            onState?(.disconnected("\(host.name) isn't on this network right now."))
            return
        }
        connect(candidates: candidates, identity: RemoteSecurity.deviceIdentity(deviceID), key: host.key, pairing: false, addresses: host.address)
    }

    public func disconnect() {
        lock.withLock { isOpen = false }
        link?.close()
        link = nil
        failPending()
    }

    /// Tries each address in turn (Bonjour first, then Wi-Fi, VPN…) until one connects.
    private func connect(candidates: [NWEndpoint], identity: String, key: Data, pairing: Bool, addresses: String?) {
        disconnect()
        onState?(.connecting)
        attempt(candidates[...], identity: identity, key: key, pairing: pairing, addresses: addresses, lastError: nil)
    }

    private func attempt(_ candidates: ArraySlice<NWEndpoint>, identity: String, key: Data, pairing: Bool, addresses: String?, lastError: String?) {
        guard let endpoint = candidates.first else {
            onState?(.disconnected(lastError ?? "Couldn't reach that Mac."))
            return
        }
        let params = RemoteSecurity.parameters(keys: [(identity, key)])
        let link = RemoteLink(NWConnection(to: endpoint, using: params), queue: queue)
        self.link = link
        let hello = RemoteMessage.hello(deviceID: deviceID, deviceName: deviceName, version: RemoteProtocol.version, pairing: pairing,
                                       proof: RemoteSecurity.proof(deviceID: deviceID, key: key))
        let ready = ReadyFlag()
        link.onState = { [weak self, weak link] state in
            guard let self, let link else { return }
            switch state {
            case .ready:
                ready.set()
                link.send(hello)
            case .closed(let reason):
                guard self.link === link else { return }
                if !ready.isSet, candidates.count > 1 {
                    // Couldn't connect this way: try the next address.
                    self.attempt(candidates.dropFirst(), identity: identity, key: key, pairing: pairing, addresses: addresses, lastError: reason)
                    return
                }
                self.lock.withLock { self.isOpen = false }
                self.failPending()
                self.onState?(.disconnected(reason))
            case .connecting: break
            }
        }
        link.onMessage = { [weak self] message in
            // Remember the address that worked, first.
            let used = Self.address(of: link.connection)
            self?.handle(message, address: Self.merge(used, addresses))
        }
        link.start()
    }

    private func handle(_ message: RemoteMessage, address: String?) {
        switch message {
        case .paired(let hostID, let hostName, let key):
            lock.withLock { isOpen = true }
            onPaired?(PairedHost(id: hostID, name: hostName, key: key, address: address))
            onState?(.connected(hostName: hostName))
        case .welcome(_, let hostName):
            lock.withLock { isOpen = true }
            onState?(.connected(hostName: hostName))
        case .status(let s):
            onStatus?(s)
        case .result(let id, let ok, let text):
            let c = lock.withLock { pending.removeValue(forKey: id) }
            c?.resume(returning: (ok, text))
        case .chatReply(let text):
            onChatReply?(text)
        case .bye(let reason):
            onState?(.disconnected(reason))
        default:
            break
        }
    }

    /// Sends a command and waits for the Mac's answer.
    @discardableResult
    public func send(_ command: RemoteCommand) async -> (ok: Bool, message: String?) {
        guard let link, lock.withLock({ isOpen }) else { return (false, "Not connected.") }
        let (ok, text) = await withCheckedContinuation { (c: CheckedContinuation<(Bool, String?), Never>) in
            let id = lock.withLock { () -> Int in
                defer { nextID += 1 }
                pending[nextID] = c
                return nextID
            }
            link.send(.command(id: id, command))
        }
        return (ok, text)
    }

    private func failPending() {
        let all = lock.withLock { () -> [CheckedContinuation<(Bool, String?), Never>] in
            defer { pending.removeAll() }
            return Array(pending.values)
        }
        all.forEach { $0.resume(returning: (false, "Disconnected.")) }
    }

    /// "ip:port,ip:port" → endpoints.
    static func endpoints(_ addresses: String?) -> [NWEndpoint] {
        (addresses ?? "").split(separator: ",").compactMap { endpoint(String($0).trimmingCharacters(in: .whitespaces)) }
    }

    /// The address that worked first, then the others (no duplicates).
    static func merge(_ used: String?, _ addresses: String?) -> String? {
        var list = (addresses ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let used { list.removeAll { $0 == used }; list.insert(used, at: 0) }
        return list.isEmpty ? nil : list.prefix(6).joined(separator: ",")
    }

    static func endpoint(_ address: String?) -> NWEndpoint? {
        guard let address, let colon = address.lastIndex(of: ":"),
              let port = NWEndpoint.Port(String(address[address.index(after: colon)...])) else { return nil }
        return .hostPort(host: NWEndpoint.Host(String(address[..<colon])), port: port)
    }

    static func address(of connection: NWConnection) -> String? {
        guard case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint else { return nil }
        var h = "\(host)"
        if let percent = h.firstIndex(of: "%") { h = String(h[..<percent]) }
        return "\(h):\(port.rawValue)"
    }
}

private final class ReadyFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
