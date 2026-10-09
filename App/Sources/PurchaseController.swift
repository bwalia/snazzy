import Entitlements
import Foundation
import Observation
import SnazzyCore
import StoreKit

/// Snazzy Pro on the Mac App Store (StoreKit 2): the products, what's been
/// bought (as `Entitlements`), buying and restoring.
///
/// While Snazzy Pro is a free beta, everything is unlocked and nothing is sold:
/// this does nothing and the Pro screens stay hidden. At launch, `policy`
/// becomes `.enforced` (debug builds can try it with `-SnazzyPro.enforcePro YES`).
@MainActor @Observable
final class PurchaseController {
    static let policy: Entitlements.Policy = {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "SnazzyPro.enforcePro") { return .enforced }
        #endif
        return .freeBeta
    }()

    private(set) var entitlements: Entitlements
    /// The Pro tiers, cheapest first. Empty outside the App Store (the website download).
    private(set) var products: [Product] = []
    private(set) var loadedProducts = false
    /// Products bought and not refunded (the lifetime tier can't be bought twice).
    private(set) var purchasedIDs: Set<String> = []
    private(set) var isBusy = false
    /// The last thing worth telling the user (a pending purchase, an error).
    var message: String?

    @ObservationIgnored private var updates: Task<Void, Never>?
    /// Transactions seen this run (purchases, and updates such as refunds), by id:
    /// `Transaction.all` can lag behind them for a moment.
    @ObservationIgnored private var known: [UInt64: Transaction] = [:]

    var isSelling: Bool { entitlements.policy == .enforced }
    var owned: Entitlement? { entitlements.owned.first }

    init(policy: Entitlements.Policy = PurchaseController.policy) {
        entitlements = Entitlements(policy: policy)
        guard isSelling else { return }
        // Purchases made elsewhere (another Mac, Ask to Buy approved, a refund) arrive here.
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let t) = result {
                    self?.known[t.id] = t
                    await t.finish()
                }
                await self?.refresh()
            }
        }
        Task { await refresh() }
    }

    func isUnlocked(_ feature: String) -> Bool { entitlements.isUnlocked(feature) }
    func limit(_ feature: String) -> Int? { entitlements.limit(feature) }

    /// Reads every verified purchase that hasn't been refunded. `Transaction.all`
    /// rather than `currentEntitlements`: that keeps only the latest year of updates.
    func refresh() async {
        var all = known
        for await result in Transaction.all {
            // A refund seen as an update wins over an older copy of the same transaction.
            if case .verified(let t) = result, all[t.id]?.revocationDate == nil { all[t.id] = t }
        }
        let purchases = all.values.filter { $0.revocationDate == nil }.map { (productID: $0.productID, date: $0.purchaseDate) }
        purchasedIDs = Set(purchases.map(\.productID))
        entitlements.owned = entitlements.catalogue.entitlement(fromStorePurchases: purchases).map { [$0] } ?? []
    }

    func loadProducts() async {
        let ids = [entitlements.catalogue.storeProducts.lifetime, entitlements.catalogue.storeProducts.updatesYear]
        do {
            products = try await Product.products(for: ids).sorted { $0.price < $1.price }
        } catch {
            Log.app.error("App Store products: \(error.localizedDescription, privacy: .public)")
        }
        loadedProducts = true
    }

    /// What a purchase came back with (from SwiftUI's `purchase` action).
    func handle(_ result: Product.PurchaseResult) async {
        switch result {
        case .success(.verified(let t)):
            known[t.id] = t
            await t.finish()
            await refresh()
            message = nil
        case .success(.unverified(_, let error)):
            message = "The App Store couldn't verify this purchase: \(error.localizedDescription)"
        case .pending:
            message = "Waiting for approval (Ask to Buy, or a payment check). Pro unlocks as soon as it's approved."
        case .userCancelled:
            break
        @unknown default:
            break
        }
    }

    /// Runs a purchase (SwiftUI's `purchase` action for a product) and handles the result.
    func buy(_ purchase: () async throws -> Product.PurchaseResult) async {
        isBusy = true
        defer { isBusy = false }
        do {
            await handle(try await purchase())
        } catch {
            message = error.localizedDescription
        }
    }

    /// Restore Purchases: asks the App Store for this Apple Account's purchases.
    func restore() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await AppStore.sync()
            await refresh()
            message = owned == nil ? "No Snazzy Pro purchases found for this Apple Account." : nil
        } catch {
            message = error.localizedDescription
        }
    }

    /// "Pro features released up to 9 October 2027", for the Pro screen.
    var coverSummary: String? {
        guard let owned else { return nil }
        guard let until = owned.updatesUntil else { return "Every Pro feature" }
        return "Pro features released up to \(until.formatted(date: .long, time: .omitted))"
    }
}
