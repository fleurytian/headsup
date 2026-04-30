import Foundation
import StoreKit

/// StoreKit 2 tip jar. Three consumable IAP products that map to "small /
/// medium / large" tip tiers. Apple takes 15-30% so we offer this *in
/// addition to* the GitHub Sponsors web link (no cut), not instead of —
/// Settings shows both. Honor-system "I donated" badge claim still works
/// for the GitHub path; this path also awards the same badge after a
/// verified purchase.
///
/// Required App Store Connect setup (see SETUP.md or below):
///   1. App Store Connect → Apps → HeadsUp → In-App Purchases → "+"
///   2. Type: Consumable
///   3. Add three products with these exact identifiers:
///        md.headsup.app.tip.small    (Tier 1 — ¥6 / $0.99)
///        md.headsup.app.tip.medium   (Tier 4 — ¥30 / $4.99)
///        md.headsup.app.tip.large    (Tier 8 — ¥128 / $19.99)
///   4. Each product needs a localized display name + description
///   5. Sign the Paid Apps agreement under Agreements, Tax, and Banking
///      if you haven't yet — IAP is gated on it.
///
/// Until those products exist in App Store Connect, `loadProducts()`
/// returns an empty array and the Tip Jar UI just shows "暂时无法加载"
/// without crashing. Open the GitHub Sponsors link in the meantime.
@MainActor
final class TipJarService: ObservableObject {
    static let shared = TipJarService()

    static let productIDs: [String] = [
        "md.headsup.app.tip.small",
        "md.headsup.app.tip.medium",
        "md.headsup.app.tip.large",
    ]

    @Published private(set) var products: [Product] = []
    @Published private(set) var loading = false
    @Published private(set) var purchasingID: String?
    @Published private(set) var lastError: String?
    @Published private(set) var thanked = false

    private var transactionListener: Task<Void, Never>?

    init() {
        // Listen for unfinished StoreKit transactions (e.g., a purchase
        // that succeeded server-side but the app crashed before we could
        // finish() it). Without this, the transaction stays in the queue
        // and re-fires forever.
        transactionListener = Task.detached { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let tx) = update {
                    await tx.finish()
                    await MainActor.run { self?.thanked = true }
                    await self?.reportPurchase(transactionId: tx.id, productId: tx.productID)
                }
            }
        }
        Task { await loadProducts() }
    }

    deinit {
        transactionListener?.cancel()
    }

    func loadProducts() async {
        loading = true
        defer { loading = false }
        do {
            let fetched = try await Product.products(for: Self.productIDs)
            // Show small → large
            self.products = fetched.sorted { $0.price < $1.price }
        } catch {
            self.lastError = error.localizedDescription
            self.products = []
        }
    }

    func purchase(_ product: Product) async {
        purchasingID = product.id
        defer { purchasingID = nil }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let tx) = verification {
                    // Always finish — consumables can't be restored, so
                    // there's no reason to keep them in the queue.
                    await tx.finish()
                    thanked = true
                    await reportPurchase(transactionId: tx.id, productId: tx.productID)
                } else if case .unverified = verification {
                    lastError = "Apple couldn't verify the transaction. Try again."
                }
            case .userCancelled:
                break
            case .pending:
                // Family Sharing "Ask to Buy" or banking auth. We'll get
                // it via Transaction.updates once it clears.
                break
            @unknown default:
                break
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Inform the server so it can award the Supporter badge. Errors are
    /// swallowed — the user already paid, we shouldn't pretend they
    /// didn't because of a network blip.
    private func reportPurchase(transactionId: UInt64, productId: String) async {
        guard let session = AuthService.shared.session else { return }
        struct Body: Encodable {
            let transaction_id: String
            let product_id: String
        }
        struct EmptyResp: Decodable {}
        let _: EmptyResp? = try? await APIClient.shared.post(
            "/v1/app/me/iap-purchased",
            body: Body(transaction_id: String(transactionId), product_id: productId),
            sessionToken: session.sessionToken
        )
    }
}
