import StoreKit
import SwiftUI

/// Snazzy Pro: what it adds, the two tiers with App Store prices, Buy and
/// Restore, and the Terms of Use and Privacy Policy (App Review requires all three).
struct ProView: View {
    let store: PurchaseController
    @Environment(\.purchase) private var purchase

    static let termsOfUse = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacyPolicy = URL(string: "https://www.snazzy.pro/privacy.html")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Snazzy Pro").font(.largeTitle.bold())
                    Text("Everything you need to make a good recording stays free. Pro saves time and adds polish.")
                        .foregroundStyle(.secondary)
                }
                if let cover = store.coverSummary {
                    Label("You have Pro: \(cover).", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.entitlements.catalogue.features) { feature in
                        Label(feature.name, systemImage: store.isUnlocked(feature.id) ? "checkmark.circle.fill" : "lock")
                    }
                }
                if store.products.isEmpty {
                    Text(store.loadedProducts
                         ? "Purchases aren't available in this copy of Snazzy Pro. Get it from the Mac App Store to buy Pro."
                         : "Loading prices…")
                        .foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(store.products, id: \.id) { product in tier(product, store: store) }
                    }
                }
                if let message = store.message {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Restore Purchases") { Task { await store.restore() } }
                        .disabled(store.isBusy)
                    Spacer()
                    Link("Terms of Use", destination: Self.termsOfUse)
                    Link("Privacy Policy", destination: Self.privacyPolicy)
                }
                .font(.callout)
            }
            .padding(24)
        }
        .task { if !store.loadedProducts { await store.loadProducts() } }
    }

    private func tier(_ product: Product, store: PurchaseController) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(product.displayName).font(.headline)
            Text(product.description).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(product.displayPrice).font(.title2.bold())
            if product.type == .nonRenewable {
                Text("One payment, not a subscription. Buy again any time for another year of new features.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if product.type == .nonConsumable, store.purchasedIDs.contains(product.id) {
                Label("Purchased", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Buy") { Task { await store.buy { try await purchase(product) } } }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isBusy)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}
