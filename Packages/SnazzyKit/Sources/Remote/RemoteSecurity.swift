import CryptoKit
import Foundation
import Network

/// Encryption and pairing for the remote link.
///
/// Every connection is TLS 1.2 with a pre-shared key (AES-128-GCM). A device
/// pairs by scanning the QR code on the Mac, which carries a one-time 256-bit
/// pairing secret (identity `pair:<hostID>`). Over that encrypted link the
/// Mac gives the device its own 256-bit key (identity `dev:<deviceID>`),
/// which both sides keep in the Keychain. A wrong key fails the TLS handshake.
public enum RemoteSecurity {
    public static func pairingIdentity(hostID: String) -> String { "pair:\(hostID)" }
    public static func deviceIdentity(_ deviceID: String) -> String { "dev:\(deviceID)" }

    public static func newKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    /// Shows the Mac that a device holds the key its hello claims: the pairing
    /// secret to pair, or that device's own key to reconnect. The TLS handshake
    /// alone only proves the device holds *some* key the Mac accepts.
    public static func proof(deviceID: String, key: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(deviceID.utf8), using: SymmetricKey(data: key)))
    }

    public static func verify(_ proof: Data?, deviceID: String, key: Data) -> Bool {
        guard let proof else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: Data(deviceID.utf8), using: SymmetricKey(data: key))
    }

    /// TCP + TLS-PSK parameters. A client passes its one key; the Mac passes
    /// every key it accepts (paired devices, plus the pairing secret while
    /// pairing is open).
    public static func parameters(keys: [(identity: String, key: Data)]) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        for k in keys {
            let key = k.key.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
            let identity = Data(k.identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
            sec_protocol_options_add_pre_shared_key(options, key, identity)
        }
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        // A phone that left the network is noticed in ~11 s, not minutes.
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.noDelay = true
        // Give up quickly on an address that doesn't answer (then try the next).
        tcp.connectionTimeout = 6
        let params = NWParameters(tls: tls, tcp: tcp)
        params.includePeerToPeer = true
        return params
    }
}

/// What the QR code on the Mac contains.
public struct PairingInvite: Sendable, Equatable {
    public var hostID: String
    public var hostName: String
    public var secret: Data
    /// "192.168.1.20:52000,10.8.0.2:52000": direct addresses (Wi-Fi, VPN…),
    /// in case Bonjour can't find the Mac (it doesn't cross VPNs).
    public var address: String?

    public init(hostID: String, hostName: String, secret: Data, address: String?) {
        self.hostID = hostID
        self.hostName = hostName
        self.secret = secret
        self.address = address
    }

    public var url: URL {
        var c = URLComponents()
        c.scheme = "snazzypro"
        c.host = "pair"
        c.queryItems = [
            URLQueryItem(name: "v", value: "\(RemoteProtocol.version)"),
            URLQueryItem(name: "h", value: hostID),
            URLQueryItem(name: "n", value: hostName),
            URLQueryItem(name: "s", value: secret.base64URL),
        ] + (address.map { [URLQueryItem(name: "a", value: $0)] } ?? [])
        return c.url!
    }

    public init?(url: URL) {
        guard url.scheme == "snazzypro", url.host() == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func v(_ n: String) -> String? { items.first { $0.name == n }?.value }
        guard let h = v("h"), !h.isEmpty, let s = v("s").flatMap(Data.init(base64URL:)), s.count == 32 else { return nil }
        self.init(hostID: h, hostName: v("n") ?? "Mac", secret: s, address: v("a"))
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }
}
