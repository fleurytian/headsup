import Foundation
import AuthenticationServices
import CryptoKit

@MainActor
final class AuthService: NSObject, ObservableObject {
    static let shared = AuthService()

    @Published private(set) var session: UserSession?
    @Published var isSigningIn = false
    @Published var lastError: String?

    private let storageKey = "headsup.userSession"

    /// Raw nonce we generated for the most recent Apple-Sign-In request.
    /// We stash it here between `prepareRequest()` and `handleAppleSignIn()`
    /// so the backend can re-derive the SHA-256 we sent to Apple.
    private(set) var pendingNonce: String?

    /// Generate a fresh random nonce and remember the raw value. Apply the
    /// SHA-256 hex digest to the request — that's what Apple expects in the
    /// `nonce` field, and what the identity_token will echo back as a claim.
    /// Stops a leaked identity_token from being replayable by anyone who
    /// doesn't know the original raw nonce.
    func prepareRequest(_ request: ASAuthorizationAppleIDRequest) {
        let raw = Self.randomNonce()
        pendingNonce = raw
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256Hex(raw)
    }

    private static func randomNonce(length: Int = 32) -> String {
        precondition(length > 0)
        let charset: [Character] = Array(
            "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._"
        )
        var result = ""
        var remaining = length
        while remaining > 0 {
            var random: UInt8 = 0
            let status = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
            if status != errSecSuccess { continue }
            if random < charset.count {
                result.append(charset[Int(random)])
                remaining -= 1
            }
        }
        return result
    }

    private static func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    override init() {
        super.init()
        loadSession()
        NotificationCenter.default.addObserver(
            forName: .headsupSessionInvalid, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.session != nil else { return }
                self.signOut()
                self.lastError = "服务器不再认你的登录,请重新登录。\nServer no longer recognizes your session. Please sign in again."
            }
        }
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

        let nonce = pendingNonce
        pendingNonce = nil

        let request = AppleSignInRequest(
            identityToken: token,
            authorizationCode: code,
            email: credential.email,
            fullName: fullName.isEmpty ? nil : fullName,
            apnsDeviceToken: PushService.shared.deviceTokenString,
            nonce: nonce
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
