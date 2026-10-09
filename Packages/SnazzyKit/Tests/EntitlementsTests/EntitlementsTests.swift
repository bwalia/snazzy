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
    /// OpsAPI's published test vectors for format v1, signed by its server's code.
    struct Vectors: Decodable {
        struct Fingerprint: Decodable { let salt, machineIdRaw, fingerprintHash: String }
        struct Case: Decodable {
            let name, typ, expect: String
            let token: [String]
            let now: TimeInterval
            let highWater: TimeInterval?
            let fingerprintHash, iss: String?
        }
        let appId: String
        let fingerprint: Fingerprint
        let cases: [Case]
    }

    static let raw = try! Data(contentsOf: Bundle.module.url(forResource: "licence-vectors", withExtension: "json", subdirectory: "Fixtures")!)
    static let vectors: Vectors = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode(Vectors.self, from: raw)
    }()
    static let keys = try! LicenceKeys(jwks: JSONSerialization.data(withJSONObject: (JSONSerialization.jsonObject(with: raw) as! [String: Any])["jwks"]!))

    static func verify(_ c: Vectors.Case) throws -> Licence {
        try Licence.verify(c.token.joined(separator: "."), kind: Licence.Kind(rawValue: c.typ)!, keys: keys, app: vectors.appId,
                           fingerprintHash: c.fingerprintHash, issuer: c.iss, now: Date(timeIntervalSince1970: c.now),
                           highWater: c.highWater.map(Date.init(timeIntervalSince1970:)) ?? .distantPast)
    }

    @Test func everyPublishedCase() {
        #expect(Self.vectors.cases.count == 20)
        for c in Self.vectors.cases {
            let result: String
            do { result = try Self.verify(c).state.rawValue }
            catch let error as LicenceError { result = "error:" + error.rawValue }
            catch { result = "error:\(error)" }
            #expect(result == c.expect, "\(c.name)")
        }
    }

    @Test func featuresBecomeAnEntitlement() throws {
        let licence = try Self.verify(Self.vectors.cases[0])
        #expect(licence.highWater == Date(timeIntervalSince1970: Self.vectors.cases[0].now))
        let entitlement = try #require(licence.entitlement)
        #expect(entitlement.features == ["export_pdf", "projects", "seats"])
        #expect(entitlement.limits == ["projects": 10])

        let catalogue = try ProCatalogue.decode(Data("""
        {"store_products": {"lifetime": "life", "updates_year": "year"}, "features": [
          {"id": "export_pdf", "name": "PDF", "released": "2025-06-01T00:00:00Z"},
          {"id": "projects", "name": "Projects", "released": "2025-06-01T00:00:00Z", "free_limit": 1},
          {"id": "seats", "name": "Seats", "released": "2025-06-01T00:00:00Z", "free_limit": 1},
          {"id": "later", "name": "Later", "released": "2027-06-01T00:00:00Z"}]}
        """.utf8))
        let e = Entitlements(policy: .enforced, owned: [entitlement], catalogue: catalogue)
        let now = Date(timeIntervalSince1970: Self.vectors.cases[0].now)
        #expect(e.isUnlocked("export_pdf", now: now) && !e.isUnlocked("later", now: now))  // after updates_until
        #expect(e.limit("projects", now: now) == 10 && e.limit("seats", now: now) == nil)
    }

    @Test func offlinePolicyDecidesPastGrace() throws {
        func licence(_ policy: String, _ state: LicenceState) throws -> Licence {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let claims = try decoder.decode(LicenceClaims.self, from: Data("""
            {"ver": 1, "aud": "a", "sub": "s", "iat": 0, "exp": 1, "grace_until": 2, "features": {"x": true}, "offline_policy": "\(policy)"}
            """.utf8))
            return Licence(claims: claims, state: state, highWater: .distantPast)
        }
        #expect(try licence("fail_open", .pastGrace).allowsUse)
        #expect(try licence("fail_closed", .pastGrace).entitlement == nil)
        #expect(try licence("fail_open", .refresh).entitlement?.features == ["x"])
        #expect(try !licence("fail_open", .accessEnded).allowsUse)
    }

    @Test func fingerprintMatchesTheFormat() {
        let f = Self.vectors.fingerprint
        #expect(MachineFingerprint.hash(salt: f.salt, id: f.machineIdRaw) == f.fingerprintHash)
        #if os(macOS)
        let mac = MachineFingerprint.hash(salt: "app_a")
        #expect(mac?.count == 64 && mac == MachineFingerprint.hash(salt: "app_a") && mac != MachineFingerprint.hash(salt: "app_b"))
        #endif
    }
}
