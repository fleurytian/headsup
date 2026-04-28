import Foundation
import AuthenticationServices

@MainActor
final class AuthService: NSObject, ObservableObject {
    static let shared = AuthService()

    @Published private(set) var session: UserSession?
    @Published var isSigningIn = false
    @Published var lastError: String?

    private let storageKey = "headsup.userSession"

    override init() {
        super.init()
        loadSession()
    }

    // ── Public ────────────────────────────────────────────────────────────────

    var isSignedIn: Bool { session != nil }

    func signOut() {
        session = nil
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    /// Exchanges an ASAuthorizationAppleIDCredential for a backend session.
    func handleAppleSignIn(_ credential: ASAuthorizationAppleIDCredential) async {
        guard let tokenData = credential.identityToken,
              let token = String(data: tokenData, encoding: .utf8) else {
            self.lastError = "Apple did not return an identity token"
            return
        }
        let codeData = credential.authorizationCode
        let code = codeData.flatMap { String(data: $0, encoding: .utf8) }

        let fullName = [credential.fullName?.givenName, credential.fullName?.familyName]
            .compactMap { $0 }.joined(separator: " ")

        let request = AppleSignInRequest(
            identityToken: token,
            authorizationCode: code,
            email: credential.email,
            fullName: fullName.isEmpty ? nil : fullName,
            apnsDeviceToken: PushService.shared.deviceTokenString
        )

        isSigningIn = true
        defer { isSigningIn = false }

        do {
            let resp: AppleSignInResponse = try await APIClient.shared.post(
                "/v1/app/sign-in-apple",
                body: request
            )
            let session = UserSession(
                userKey: resp.userKey,
                sessionToken: resp.sessionToken,
                appleUserId: resp.appleUserId
            )
            self.session = session
            persistSession(session)
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    // ── Persistence (UserDefaults — MVP. Move to Keychain before launch) ─────

    private func loadSession() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let s = try? JSONDecoder().decode(UserSession.self, from: data) else { return }
        self.session = s
    }

    private func persistSession(_ s: UserSession) {
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
