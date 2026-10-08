import Foundation
import Network

/// A device allowed to control this Mac.
public struct TrustedDevice: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var key: Data
    public var paired: Date

    public init(id: String, name: String, key: Data, paired: Date = Date()) {
        self.id = id
        self.name = name
        self.key = key
        self.paired = paired
    }
}

/// The Mac side: advertises over Bonjour, accepts encrypted connections from
/// paired devices (and one new device while pairing is open), forwards their
/// commands to the app and sends them status updates.
public final class RemoteHost: @unchecked Sendable {
    public let hostID: String
    public let hostName: String

    /// Runs a command from a device; returns (ok, message).
    public var onCommand: (@Sendable (_ deviceID: String, RemoteCommand) async -> (Bool, String?))?
    /// A new device paired: store it (its key belongs in the Keychain).
    public var onPaired: (@Sendable (TrustedDevice) -> Void)?
    /// Names of connected devices changed.
    public var onConnected: (@Sendable ([String]) -> Void)?
    /// Listener problems (nil when listening).
    public var onListening: (@Sendable (_ port: UInt16?, _ error: String?) -> Void)?

    private let queue = DispatchQueue(label: "com.snazzy.pro.remote-host")
    private let lock = NSLock()
    private var devices: [String: TrustedDevice]
    private var pairingSecret: Data?
    private var pairingExpires = Date.distantPast
    private var listener: NWListener?
    private var links: [ObjectIdentifier: (link: RemoteLink, deviceID: String?, name: String?)] = [:]
    private var lastStatus: RemoteStatus?
    private var port: NWEndpoint.Port = .any

    public init(hostID: String, hostName: String, devices: [TrustedDevice]) {
        self.hostID = hostID
        self.hostName = hostName
        self.devices = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
    }

    // MARK: Listening

    /// Starts (or restarts, keeping the port) with the current set of keys.
    public func start() {
        queue.async { [weak self] in self?.listen() }
    }

    /// Always on `queue`.
    private func listen() {
        let keys: [(identity: String, key: Data)] = lock.withLock {
            var k = devices.values.map { (RemoteSecurity.deviceIdentity($0.id), $0.key) }
            if let s = pairingSecret, pairingExpires > Date() { k.append((RemoteSecurity.pairingIdentity(hostID: hostID), s)) }
            return k
        }
        // Reopen on the same port once the old listener has fully closed.
        if let old = listener {
            listener = nil
            old.stateUpdateHandler = { [weak self] state in
                guard case .cancelled = state, let self else { return }
                self.queue.async { [weak self] in self?.listen() }
            }
            old.newConnectionHandler = nil
            old.cancel()
            return
        }
        // TLS-PSK needs at least one key; with none, there's nothing to accept.
        guard !keys.isEmpty else {
            onListening?(nil, nil)
            return
        }
        let params = RemoteSecurity.parameters(keys: keys)
        params.allowLocalEndpointReuse = true
        do {
            let l = try NWListener(using: params, on: port)
            l.service = NWListener.Service(name: hostName, type: RemoteProtocol.serviceType, domain: nil,
                                           txtRecord: NWTXTRecord(["id": hostID, "v": "\(RemoteProtocol.version)"]))
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { [weak self, weak l] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let p = l?.port { self.port = p }
                    self.onListening?(l?.port?.rawValue, nil)
                case .failed(let e):
                    self.onListening?(nil, e.localizedDescription)
                default: break
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            onListening?(nil, error.localizedDescription)
        }
    }

    public func stop() {
        queue.sync {
            listener?.stateUpdateHandler = nil
            listener?.cancel()
            listener = nil
        }
        let all = lock.withLock { links.values.map(\.link) }
        all.forEach { $0.close("Snazzy Pro stopped remote control.") }
    }

    /// The port once listening (nil before the listener is ready).
    public var listeningPort: UInt16? {
        queue.sync {
            guard listener?.state == .ready, let p = listener?.port?.rawValue, p != 0 else { return nil }
            return p
        }
    }

    // MARK: Pairing

    /// Opens pairing for `seconds` and returns the invite for the QR code.
    public func openPairing(address: String?, seconds: TimeInterval = 180) -> PairingInvite {
        let secret = RemoteSecurity.newKey()
        lock.withLock {
            pairingSecret = secret
            pairingExpires = Date().addingTimeInterval(seconds)
        }
        start()
        return PairingInvite(hostID: hostID, hostName: hostName, secret: secret, address: address)
    }

    public func closePairing() {
        let wasOpen = lock.withLock { () -> Bool in
            defer { pairingSecret = nil }
            return pairingSecret != nil
        }
        if wasOpen { start() }
    }

    public func removeDevice(_ id: String) {
        let toClose = lock.withLock { () -> [RemoteLink] in
            devices.removeValue(forKey: id)
            return links.values.filter { $0.deviceID == id }.map(\.link)
        }
        toClose.forEach { $0.close("This device was removed on the Mac.") }
        start()
    }

    public var connectedNames: [String] { lock.withLock { links.values.compactMap(\.name).sorted() } }

    // MARK: Status

    public func publish(_ status: RemoteStatus) {
        let targets = lock.withLock { () -> [RemoteLink] in
            guard status != lastStatus else { return [] }
            lastStatus = status
            return links.values.filter { $0.deviceID != nil }.map(\.link)
        }
        targets.forEach { $0.send(.status(status)) }
    }

    public func sendChatReply(_ text: String, to deviceID: String) {
        let targets = lock.withLock { links.values.filter { $0.deviceID == deviceID }.map(\.link) }
        targets.forEach { $0.send(.chatReply(text)) }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let link = RemoteLink(connection, queue: queue)
        let id = ObjectIdentifier(link)
        lock.withLock { links[id] = (link, nil, nil) }
        link.onState = { [weak self] state in
            guard case .closed = state, let self else { return }
            let names = self.lock.withLock { () -> [String] in
                self.links.removeValue(forKey: id)
                return self.links.values.compactMap(\.name).sorted()
            }
            self.onConnected?(names)
        }
        link.onMessage = { [weak self, weak link] message in
            guard let self, let link else { return }
            self.handle(message, from: link, id: id)
        }
        link.start()
    }

    private func handle(_ message: RemoteMessage, from link: RemoteLink, id: ObjectIdentifier) {
        switch message {
        case .hello(let deviceID, let deviceName, let version, let pairing):
            guard version == RemoteProtocol.version else {
                link.close("Update Snazzy Pro on this device and the Mac to the same version.")
                return
            }
            let name = String(deviceName.prefix(60))
            if pairing {
                // Only someone who scanned the current QR code can get here (the
                // TLS handshake needs the pairing secret), unless they hold a
                // device key; either way they're allowed in.
                let device = TrustedDevice(id: deviceID, name: name, key: RemoteSecurity.newKey())
                lock.withLock {
                    devices[deviceID] = device
                    pairingSecret = nil  // one device per QR code
                    links[id] = (link, deviceID, name)
                }
                onPaired?(device)
                link.send(.paired(hostID: hostID, hostName: hostName, deviceKey: device.key))
                // Accept the new key, stop accepting the pairing secret.
                start()
            } else {
                let known = lock.withLock { devices[deviceID] != nil }
                guard known else {
                    link.close("This device isn't paired with this Mac. Pair again.")
                    return
                }
                lock.withLock { links[id] = (link, deviceID, name) }
                link.send(.welcome(hostID: hostID, hostName: hostName))
            }
            if let s = lock.withLock({ lastStatus }) { link.send(.status(s)) }
            onConnected?(connectedNames)
        case .command(let commandID, let command):
            guard let deviceID = lock.withLock({ links[id]?.deviceID }) else {
                link.close("Say hello first.")
                return
            }
            Task {
                let (ok, text) = await self.onCommand?(deviceID, command) ?? (false, "Not available.")
                link.send(.result(id: commandID, ok: ok, message: text))
            }
        case .bye:
            link.close()
        default:
            break  // host-to-device messages aren't expected from devices
        }
    }
}
