import CryptoKit
import Foundation
#if os(macOS)
import IOKit
#endif

// OpsAPI licence files and entitlement tokens, format v1 (OpsAPI docs/LICENCE_FORMAT.md):
// compact JWS signed with ES256, checked offline against the JWKS shipped with the app.

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

/// What a signed licence says. Unknown claims are ignored, as the format requires.
public struct LicenceClaims: Decodable, Equatable, Sendable {
    /// A feature's value. A missing feature is off.
    public enum Feature: Decodable, Equatable, Sendable {
        case on(Bool)
        case limit(Int)
        case unlimited
        case unknown

        public init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if value.decodeNil() { self = .unlimited }
            else if let on = try? value.decode(Bool.self) { self = .on(on) }
            else if let limit = try? value.decode(Int.self) { self = .limit(limit) }
            else { self = .unknown }
        }
    }

    public let ver: Int
    public let iss: String?
    public let aud: String
    public let sub: String
    public let iat: Date
    /// Refresh by then.
    public let exp: Date
    /// Usable without a refresh until then.
    public let graceUntil: Date
    public let planKey: String?
    public let features: [String: Feature]
    /// Access ends then (a fixed-term pass); nil = for good.
    public let accessUntil: Date?
    /// Releases up to then are covered; nil = all of them.
    public let updatesUntil: Date?
    public let fingerprintHash: String?
    /// "fail_open" keeps working past the grace period while OpsAPI can't be reached.
    public let offlinePolicy: String?

    // Not convertFromSnakeCase: that would rename the feature ids too.
    enum CodingKeys: String, CodingKey {
        case ver, iss, aud, sub, iat, exp, features
        case graceUntil = "grace_until", planKey = "plan_key", accessUntil = "access_until"
        case updatesUntil = "updates_until", fingerprintHash = "fingerprint_hash", offlinePolicy = "offline_policy"
    }
}

public enum LicenceState: String, Equatable, Sendable {
    case valid
    /// Use it, and refresh it when online.
    case refresh
    /// Refresh now; OpsAPI's answer decides. If it can't be reached, `offline_policy` does.
    case pastGrace = "past_grace"
    /// A fixed-term pass has run out.
    case accessEnded = "access_ended"
}

/// Why a token can't be trusted at all. Raw values are the format's error codes.
public enum LicenceError: String, Error, Equatable {
    case malformed
    case badAlg = "bad_alg"
    case badType = "bad_type"
    case unknownKey = "unknown_key"
    case badSignature = "bad_signature"
    case badVersion = "bad_version"
    case wrongApp = "wrong_app"
    case wrongIssuer = "wrong_issuer"
    case wrongMachine = "wrong_machine"
}

/// A token that's been checked: signed by one of the keys, for this app and this machine.
public struct Licence: Sendable {
    public enum Kind: String, Sendable {
        case licenceFile = "opsapi-license+jwt"
        case entitlementToken = "opsapi-entitlements+jwt"
    }

    /// The clock difference tolerated, in seconds.
    public static let skew: TimeInterval = 300

    public let claims: LicenceClaims
    public let state: LicenceState
    /// The latest time seen. Save it and pass it to the next check, so turning the clock back doesn't help.
    public let highWater: Date

    /// Whether to allow use when a refresh isn't possible. A refresh answer from OpsAPI overrides it.
    public var allowsUse: Bool {
        switch state {
        case .valid, .refresh: true
        case .pastGrace: claims.offlinePolicy == "fail_open"
        case .accessEnded: false
        }
    }

    /// What it unlocks; nil when it doesn't allow use.
    public var entitlement: Entitlement? {
        guard allowsUse else { return nil }
        var included = Set<String>(), limits: [String: Int] = [:]
        for (id, value) in claims.features {
            switch value {
            case .on(true), .unlimited: included.insert(id)
            case .limit(let n): included.insert(id); limits[id] = n
            case .on(false), .unknown: break
            }
        }
        return Entitlement(source: .licence, features: included, limits: limits, updatesUntil: claims.updatesUntil, accessUntil: claims.accessUntil)
    }

    /// Checks a token step by step, stopping at the first failure. `issuer` pins the
    /// OpsAPI that must have signed it; `highWater` is the value saved after the last check.
    public static func verify(_ token: String, kind: Kind = .licenceFile, keys: LicenceKeys, app: String,
                              fingerprintHash: String? = nil, issuer: String? = nil,
                              now: Date = Date(), highWater: Date = .distantPast) throws -> Licence {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        struct Header: Decodable { let alg: String?, typ: String?, kid: String? }
        guard parts.count == 3, let headerData = Data(base64URL: parts[0]),
              let header = try? JSONDecoder().decode(Header.self, from: headerData) else { throw LicenceError.malformed }
        guard header.alg == "ES256" else { throw LicenceError.badAlg }
        guard header.typ == kind.rawValue else { throw LicenceError.badType }
        guard let key = header.kid.flatMap({ keys.keys[$0] }) else { throw LicenceError.unknownKey }
        guard let signature = Data(base64URL: parts[2]), signature.count == 64,
              let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: signature),
              key.isValidSignature(ecdsa, for: Data((parts[0] + "." + parts[1]).utf8)) else { throw LicenceError.badSignature }

        struct Version: Decodable { let ver: Int? }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let payload = Data(base64URL: parts[1]), let version = try? decoder.decode(Version.self, from: payload) else {
            throw LicenceError.malformed
        }
        guard version.ver == 1 else { throw LicenceError.badVersion }
        guard let claims = try? decoder.decode(LicenceClaims.self, from: payload) else { throw LicenceError.malformed }
        guard claims.aud == app else { throw LicenceError.wrongApp }
        if let issuer, claims.iss != issuer { throw LicenceError.wrongIssuer }
        if kind == .licenceFile, claims.fingerprintHash == nil || claims.fingerprintHash != fingerprintHash {
            throw LicenceError.wrongMachine
        }

        // The clock never goes back past what's been seen; a clock behind the token uses its issue time.
        let t = max(now, highWater, claims.iat.addingTimeInterval(-skew))
        let state: LicenceState
        if let end = claims.accessUntil, t > end.addingTimeInterval(skew) { state = .accessEnded }
        else if t <= claims.exp.addingTimeInterval(skew) { state = .valid }
        else if t <= claims.graceUntil.addingTimeInterval(skew) { state = .refresh }
        else { state = .pastGrace }
        return Licence(claims: claims, state: state, highWater: max(highWater, now, claims.iat))
    }
}

/// This machine's id, salted and hashed: the raw id never leaves it, and the per-app salt
/// (OpsAPI's `fingerprint_salt`) stops hashes being linked across apps.
public enum MachineFingerprint {
    public static func hash(salt: String, id: String) -> String {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return SHA256.hash(data: Data((salt + ":" + id).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    #if os(macOS)
    /// This Mac's hash, from its IOPlatformUUID; nil if IOKit can't read it.
    public static func hash(salt: String) -> String? {
        platformUUID.map { hash(salt: salt, id: $0) }
    }

    static var platformUUID: String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
    }
    #endif
}

extension Data {
    init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }
}
