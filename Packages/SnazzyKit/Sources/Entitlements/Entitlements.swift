import Foundation

/// A Pro feature and the day it was released: a purchase covers the features
/// released up to its date (and up to a year later with the updates tier).
/// The list is data, in pro-features.json.
public struct ProFeature: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let released: Date
    /// For a limit (say, presets): how many the free version allows. nil = on or off.
    public let freeLimit: Int?
}

/// The Pro features and the App Store products, from pro-features.json.
public struct ProCatalogue: Codable, Sendable {
    public struct StoreProducts: Codable, Sendable {
        public let lifetime: String
        public let updatesYear: String
    }

    public let storeProducts: StoreProducts
    public let features: [ProFeature]

    public static let bundled: ProCatalogue = {
        guard let url = Bundle.module.url(forResource: "pro-features", withExtension: "json"),
              let data = try? Data(contentsOf: url), let catalogue = try? decode(data) else {
            preconditionFailure("pro-features.json is missing or invalid")
        }
        return catalogue
    }()

    public static func decode(_ data: Data) throws -> ProCatalogue {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ProCatalogue.self, from: data)
    }

    /// App Store purchases as one entitlement. A lifetime purchase covers what was
    /// released up to its date; each year of updates covers up to a year after the later
    /// of its date and the cover so far, so buying it again extends it.
    public func entitlement(fromStorePurchases purchases: [(productID: String, date: Date)]) -> Entitlement? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var until: Date?
        for purchase in purchases.sorted(by: { $0.date < $1.date }) {
            let from = max(until ?? purchase.date, purchase.date)
            switch purchase.productID {
            case storeProducts.lifetime: until = from
            case storeProducts.updatesYear: until = calendar.date(byAdding: .year, value: 1, to: from)
            default: continue
            }
        }
        return until.map { Entitlement(source: .appStore, updatesUntil: $0) }
    }
}

/// What someone has bought, from any channel, reduced to what it unlocks.
public struct Entitlement: Equatable, Sendable {
    public enum Source: String, Sendable {
        case appStore, licence
    }

    public var source: Source
    /// The Pro features included; nil = all of them.
    public var features: Set<String>?
    /// Limits it sets (licences can carry them); a feature that's included without one is unlimited.
    public var limits: [String: Int]
    /// Covers features released on or before this; nil = every feature, now and future.
    public var updatesUntil: Date?
    /// When access ends; nil = for good.
    public var accessUntil: Date?

    public init(source: Source, features: Set<String>? = nil, limits: [String: Int] = [:], updatesUntil: Date? = nil, accessUntil: Date? = nil) {
        self.source = source
        self.features = features
        self.limits = limits
        self.updatesUntil = updatesUntil
        self.accessUntil = accessUntil
    }

    func covers(_ feature: ProFeature, at now: Date) -> Bool {
        if let end = accessUntil, now > end { return false }
        if let included = features, !included.contains(feature.id) { return false }
        if let until = updatesUntil, feature.released > until { return false }
        return true
    }
}

/// Whether a Pro feature may be used, from what's been bought through any channel.
/// While Snazzy Pro is a free beta, everything is unlocked: enforcing is a policy
/// switch at launch, not new code.
public struct Entitlements: Sendable {
    public enum Policy: String, Sendable {
        case freeBeta = "free_beta"
        case enforced
    }

    public var policy: Policy
    public var owned: [Entitlement]
    public let catalogue: ProCatalogue

    public init(policy: Policy = .freeBeta, owned: [Entitlement] = [], catalogue: ProCatalogue = .bundled) {
        self.policy = policy
        self.owned = owned
        self.catalogue = catalogue
    }

    /// Anything that isn't a Pro feature is always unlocked.
    public func isUnlocked(_ id: String, now: Date = Date()) -> Bool {
        guard policy == .enforced, let feature = catalogue.features.first(where: { $0.id == id }) else { return true }
        return owned.contains { $0.covers(feature, at: now) }
    }

    /// For a limit feature: how many are allowed, or nil for no limit.
    public func limit(_ id: String, now: Date = Date()) -> Int? {
        guard policy == .enforced, let feature = catalogue.features.first(where: { $0.id == id }) else { return nil }
        let covering = owned.filter { $0.covers(feature, at: now) }
        guard !covering.isEmpty else { return feature.freeLimit }
        if covering.contains(where: { $0.limits[id] == nil }) { return nil }
        // A purchase never allows fewer than the free version does.
        return max(covering.compactMap { $0.limits[id] }.max() ?? 0, feature.freeLimit ?? 0)
    }
}
