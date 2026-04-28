import Foundation

@MainActor
final class DeepLinkHandler: ObservableObject {
    static let shared = DeepLinkHandler()

    /// Pending authorization request — when set, UI shows the consent screen.
    @Published var pendingAuthorize: PendingAuthorize?

    struct PendingAuthorize: Identifiable {
        let id = UUID()
        let token: String
        let agentId: String
    }

    /// Called when the app opens via headsup://authorize?token=...&agent_id=...
    func handle(url: URL) {
        guard url.scheme == "headsup", url.host == "authorize" else { return }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let token = components?.queryItems?.first(where: { $0.name == "token" })?.value,
              let agentId = components?.queryItems?.first(where: { $0.name == "agent_id" })?.value else {
            return
        }
        pendingAuthorize = PendingAuthorize(token: token, agentId: agentId)
    }

    /// On launch, check if Safari left a pending headsup:// URL on the clipboard.
    /// Used for "deferred deep link" — user tapped invite link → installed app → opened it
    /// → we resume the authorization automatically.
    func consumeClipboardIfPresent() {
        let pb = UIPasteboard.general
        // hasURLs / hasStrings let us check without iOS surfacing the "X pasted from..." banner
        guard pb.hasStrings || pb.hasURLs else { return }
        var candidate: String?
        if let url = pb.url, url.scheme == "headsup" {
            candidate = url.absoluteString
        } else if let s = pb.string, s.lowercased().hasPrefix("headsup://") {
            candidate = s
        }
        if let c = candidate, let url = URL(string: c) {
            handle(url: url)
            // Don't clear the clipboard — user might want to paste something else.
        }
    }
}

import UIKit

    /// Confirm the binding with the backend.
    func confirm(_ pending: PendingAuthorize) async throws {
        guard let session = AuthService.shared.session else {
            throw APIError.http(401, "Not signed in")
        }
        let req = AuthConfirmRequest(token: pending.token, userKey: session.userKey)
        let _: AuthConfirmResponse = try await APIClient.shared.post(
            "/v1/app/authorize/confirm",
            body: req,
            sessionToken: session.sessionToken
        )
        pendingAuthorize = nil
    }

    func cancel() {
        pendingAuthorize = nil
    }
}
