import Foundation
import Testing
@testable import Entitlements

private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

/// A small catalogue, so the rules are checked apart from the shipped list.
private let catalogue = try! ProCatalogue.decode(Data("""
{"store_products": {"lifetime": "life", "updates_year": "year"},
 "features": [
  {"id": "old", "name": "Old", "released": "2026-01-01T00:00:00Z"},
  {"id": "new", "name": "New", "released": "2027-06-01T00:00:00Z"},
  {"id": "presets", "name": "Presets", "released": "2026-01-01T00:00:00Z", "free_limit": 3}
 ]}
""".utf8))

@Suite struct EntitlementsTests {
    @Test func shippedCatalogueLoads() {
        let ids = ProCatalogue.bundled.features.map(\.id)
        #expect(!ids.isEmpty && Set(ids).count == ids.count)
        #expect(ProCatalogue.bundled.storeProducts.lifetime == "com.snazzy.pro.pro.lifetime")
    }

    @Test func freeBetaUnlocksEverything() {
        let e = Entitlements(catalogue: catalogue)
        #expect(e.isUnlocked("old") && e.isUnlocked("new"))
        #expect(e.limit("presets") == nil)
    }

    @Test func enforcedLocksOnlyProFeatures() {
        let e = Entitlements(policy: .enforced, catalogue: catalogue)
        #expect(!e.isUnlocked("old"))
        #expect(e.isUnlocked("recording"))
        #expect(e.limit("presets") == 3)
    }

    @Test func lifetimeCoversWhatWasReleasedByThen() throws {
        let owned = try #require(catalogue.entitlement(fromStorePurchases: [("life", date("2026-10-08T00:00:00Z"))]))
        let e = Entitlements(policy: .enforced, owned: [owned], catalogue: catalogue)
        #expect(e.isUnlocked("old") && !e.isUnlocked("new"))
        #expect(e.limit("presets") == nil)
    }

    @Test func updateYearsStack() {
        let bought = date("2026-10-08T00:00:00Z")
        #expect(catalogue.entitlement(fromStorePurchases: [("year", bought)])?.updatesUntil == date("2027-10-08T00:00:00Z"))
        // Bought again early: the new year starts where the last one ends.
        let twice = catalogue.entitlement(fromStorePurchases: [("year", date("2027-03-01T00:00:00Z")), ("year", bought)])
        #expect(twice?.updatesUntil == date("2028-10-08T00:00:00Z"))
        // Bought after a gap: the year starts on the day it's bought.
        let lapsed = catalogue.entitlement(fromStorePurchases: [("life", bought), ("year", date("2028-01-01T00:00:00Z"))])
        #expect(lapsed?.updatesUntil == date("2029-01-01T00:00:00Z"))
        // A lifetime purchase never shortens the cover already bought.
        let both = catalogue.entitlement(fromStorePurchases: [("year", bought), ("life", date("2027-01-01T00:00:00Z"))])
        #expect(both?.updatesUntil == date("2027-10-08T00:00:00Z"))
        #expect(catalogue.entitlement(fromStorePurchases: [("something.else", bought)]) == nil)
    }

    @Test func accessEndsAndLimitsNeverDropBelowFree() {
        let now = date("2026-10-08T00:00:00Z")
        let ended = Entitlement(source: .licence, accessUntil: now.addingTimeInterval(-1))
        #expect(!Entitlements(policy: .enforced, owned: [ended], catalogue: catalogue).isUnlocked("old", now: now))
        let one = Entitlement(source: .licence, features: ["presets"], limits: ["presets": 1])
        #expect(Entitlements(policy: .enforced, owned: [one], catalogue: catalogue).limit("presets", now: now) == 3)
    }
}

@Suite struct LicenceTests {
    /// Signed by Python `cryptography`, an independent ES256 implementation, with a
    /// throwaway key. Each token is stored as its three parts so secret scanners don't
    /// take it for a live one.
    struct Vectors: Decodable {
        let iat: TimeInterval
        let valid, tampered, unknownKid, algNone, failOpen, noFingerprint: [String]
    }

    static let raw = try! Data(contentsOf: Bundle.module.url(forResource: "licence-vectors", withExtension: "json", subdirectory: "Fixtures")!)
    static let vectors: Vectors = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode(Vectors.self, from: raw)
    }()
    static let keys = try! LicenceKeys(jwks: JSONSerialization.data(withJSONObject: (JSONSerialization.jsonObject(with: raw) as! [String: Any])["jwks"]!))
    static let machine = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
    static let day: TimeInterval = 86_400

    func verify(_ parts: [String], app: String = "app_test", machine: String = Self.machine, after: TimeInterval = Self.day) throws -> Licence {
        try Licence.verify(parts.joined(separator: "."), keys: Self.keys, app: app, fingerprintHash: machine, now: Date(timeIntervalSince1970: Self.vectors.iat + after))
    }

    @Test func validLicenceUnlocksItsFeatures() throws {
        let licence = try verify(Self.vectors.valid)
        #expect(licence.status == .valid && licence.isUsable)
        let entitlement = try #require(licence.entitlement)
        #expect(entitlement.features == ["relayout", "export_4k", "presets"])
        #expect(entitlement.limits == ["presets": 50])
        #expect(entitlement.updatesUntil == Date(timeIntervalSince1970: Self.vectors.iat + 365 * Self.day))

        let e = Entitlements(policy: .enforced, owned: [entitlement])
        let now = Date(timeIntervalSince1970: Self.vectors.iat)
        #expect(e.isUnlocked("relayout", now: now) && !e.isUnlocked("vertical_clips", now: now))
        #expect(e.limit("presets", now: now) == 50)
    }

    @Test func graceThenExpired() throws {
        let grace = try verify(Self.vectors.valid, after: 31 * Self.day)
        #expect(grace.status == .grace(until: Date(timeIntervalSince1970: Self.vectors.iat + 44 * Self.day)) && grace.isUsable)
        let expired = try verify(Self.vectors.valid, after: 45 * Self.day)
        #expect(expired.status == .expired && !expired.isUsable && expired.entitlement == nil)
        let failOpen = try verify(Self.vectors.failOpen, after: 45 * Self.day)
        #expect(failOpen.status == .expired && failOpen.isUsable)
    }

    @Test func rejectsBadLicences() throws {
        #expect(throws: LicenceError.badSignature) { try verify(Self.vectors.tampered) }
        #expect(throws: LicenceError.unknownKey) { try verify(Self.vectors.unknownKid) }
        #expect(throws: LicenceError.unsupported) { try verify(Self.vectors.algNone) }
        #expect(throws: LicenceError.malformed) { try verify(["not", "a-licence"]) }
        #expect(throws: LicenceError.wrongApp) { try verify(Self.vectors.valid, app: "another_app") }
        #expect(throws: LicenceError.wrongMachine) { try verify(Self.vectors.valid, machine: String(repeating: "0", count: 64)) }
        #expect(throws: LicenceError.notYetValid) { try verify(Self.vectors.valid, after: -3600) }
        _ = try verify(Self.vectors.valid, after: -60)  // within clock skew
        _ = try verify(Self.vectors.noFingerprint, machine: "any")
    }

    #if os(macOS)
    @Test func fingerprintIsStableAndSalted() throws {
        let a = try #require(MachineFingerprint.hash(salt: "app_a"))
        #expect(a.count == 64 && a == MachineFingerprint.hash(salt: "app_a"))
        #expect(a != MachineFingerprint.hash(salt: "app_b"))
    }
    #endif
}
