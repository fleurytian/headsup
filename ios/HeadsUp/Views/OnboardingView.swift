import SwiftUI
import AuthenticationServices

struct OnboardingView: View {
    @EnvironmentObject var auth: AuthService
    @EnvironmentObject var push: PushService

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                Text("HeadsUp")
                    .font(.largeTitle.bold())
                Text("Let your AI agents talk back to you in your notification bar.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            Spacer()

            VStack(spacing: 12) {
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    switch result {
                    case .success(let auth):
                        if let credential = auth.credential as? ASAuthorizationAppleIDCredential {
                            Task {
                                await self.auth.handleAppleSignIn(credential)
                                if self.auth.isSignedIn {
                                    await self.push.requestAuthorization()
                                }
                            }
                        }
                    case .failure(let error):
                        self.auth.lastError = error.localizedDescription
                    }
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 50)
                .padding(.horizontal, 32)

                if let err = auth.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 32)
                }
            }

            Text("By continuing you agree to receive interactive notifications from agents you authorize.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.bottom, 24)
        }
    }
}
