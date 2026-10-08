import CryptoKit
import Foundation
#if os(macOS)
import IOKit
#endif

/// The public keys licences are signed with: the licence server's JWKS. Keys of other
/// types are skipped, so the server can publish more without breaking older apps.
public struct LicenceKeys: Sendable {
    let keys: [String: P256.Signing.PublicKey]

    public init(jwks: Data) throws {
        struct JWK: Decodable { let kty, crv, kid, x, y: String? }
        struct JWKS: Decodable { let keys: [JWK] }
        var keys: [String: P256.Signing.PublicKey] = [:]
        for jwk in try JSONDecoder().decode(JWKS.self, from: jwks).keys where jwk.kty == "EC" && jwk.crv == "P-256" {
            guard let kid = jwk.kid, let x = jwk.x.flatMap(Data.init(base64URL:)), let y = jwk.y.flatMap(Data.init(base64URL:)),
                  let key = try? P256.Signing.PublicKey(rawRepresentation: x + y) else { continue }
            keys[kid] = key
        }
        self.keys = keys
    }
}

/// What a signed licence says (format version 1).
public struct LicenceClaims: Decodable, Equatable, Sendable {
    /// A feature's value: on or off, or a limit (which also means on).
    public enum Feature: Decodable, Equatable, Sendable {
        case on(Bool)
        case limit(Int)
        case unknown

        public init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let on = try? value.decode(Bool.self) { self = .on(on) }
            else if let limit = try? value.decode(Int.self) { self = .limit(limit) }
            else { self = .unknown }
        }
    }

    public let v: Int
    public let sub: String
    public let aud: String
    public let iat: Date
    /// Refresh by then; after it the licence is in its grace period.
    public let exp: Date
    public let graceUntil: Date?
    public let planKey: String?
    public let features: [String: Feature]
    public let accessUntil: Date?
    public let updatesUntil: Date?
    public let fingerprintHash: String?
    /// "fail_open" keeps the licence usable after its grace period while the server can't be reached.
    public let offlinePolicy: String?

    // Not convertFromSnakeCase: that would rename the feature ids too.
    enum CodingKeys: String, CodingKey {
        case v, sub, aud, iat, exp, features
        case graceUntil = "grace_until", planKey = "plan_key", accessUntil = "access_until"
        case updatesUntil = "updates_until", fingerprintHash = "fingerprint_hash", offlinePolicy = "offline_policy"
    }
}

public enum LicenceStatus: Equatable, Sendable {
    case valid
    /// Past its refresh date but still usable until then.
    case grace(until: Date)
    case expired
}

public enum LicenceError: Error, Equatable {
    case malformed, unsupported, unknownKey, badSignature, wrongApp, wrongMachine, notYetValid
}

/// A licence that's been checked: signed by one of the keys, for this app and this machine.
public struct Licence: Sendable {
    public let claims: LicenceClaims
    public let status: LicenceStatus

    public var isUsable: Bool { status != .expired || claims.offlinePolicy == "fail_open" }

    /// What it unlocks; nil once it's no longer usable.
    public var entitlement: Entitlement? {
        guard isUsable else { return nil }
        var included = Set<String>(), limits: [String: Int] = [:]
        for (id, value) in claims.features {
            switch value {
            case .on(true): included.insert(id)
            case .limit(let n): included.insert(id); limits[id] = n
            case .on(false), .unknown: break
            }
        }
        return Entitlement(source: .licence, features: included, limits: limits, updatesUntil: claims.updatesUntil, accessUntil: claims.accessUntil)
    }

    /// Checks a compact-JWS (ES256) licence. `now` is the caller's to pass, so it can
    /// use the latest time it has seen if the clock has been moved back.
    public static func verify(_ token: String, keys: LicenceKeys, app: String, fingerprintHash: String,
                              now: Date = Date(), skew: TimeInterval = 300) throws -> Licence {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        struct Header: Decodable { let alg: String; let kid: String? }
        guard parts.count == 3, let headerData = Data(base64URL: parts[0]), let payload = Data(base64URL: parts[1]),
              let signature = Data(base64URL: parts[2]),
              let header = try? JSONDecoder().decode(Header.self, from: headerData) else { throw LicenceError.malformed }
        guard header.alg == "ES256" else { throw LicenceError.unsupported }
        guard let key = header.kid.flatMap({ keys.keys[$0] }) else { throw LicenceError.unknownKey }
        guard let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: signature),
              key.isValidSignature(ecdsa, for: Data((parts[0] + "." + parts[1]).utf8)) else { throw LicenceError.badSignature }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let claims = try? decoder.decode(LicenceClaims.self, from: payload) else { throw LicenceError.malformed }
        guard claims.v == 1 else { throw LicenceError.unsupported }
        guard claims.aud == app else { throw LicenceError.wrongApp }
        if let hash = claims.fingerprintHash, hash != fingerprintHash { throw LicenceError.wrongMachine }
        guard claims.iat <= now.addingTimeInterval(skew) else { throw LicenceError.notYetValid }

        let status: LicenceStatus
        if now < claims.exp { status = .valid }
        else if let grace = claims.graceUntil, now < grace { status = .grace(until: grace) }
        else { status = .expired }
        return Licence(claims: claims, status: status)
    }
}

#if os(macOS)
/// This Mac's id, salted and hashed: the raw id never leaves the Mac, and the per-app
/// salt stops hashes being linked across apps.
public enum MachineFingerprint {
    public static func hash(salt: String) -> String? {
        platformUUID.map { hash(salt: salt, id: $0) }
    }

    static func hash(salt: String, id: String) -> String {
        SHA256.hash(data: Data((salt + ":" + id).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static var platformUUID: String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
    }
}
#endif

extension Data {
    init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }
}
