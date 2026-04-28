import SwiftUI
import AuthenticationServices

struct OnboardingView: View {
    @EnvironmentObject var auth: AuthService
    @EnvironmentObject var push: PushService

    var body: some View {
        ZStack {
            HU.C.bg.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Spacer().frame(height: 60)

                // top eyebrow
                Eyebrow(text: "headsup · md")
                    .padding(.horizontal, 32)

                Spacer().frame(height: 14)

                // single sun mark, very small, accent only
                Circle()
                    .fill(HU.C.accent)
                    .frame(width: 18, height: 18)
                    .padding(.horizontal, 32)

                Spacer().frame(height: 30)

                // headline — large, generous letter spacing
                VStack(alignment: .leading, spacing: 10) {
                    Text("一个让 AI\n来通知栏找你的\n小工具。")
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundStyle(HU.C.ink)
                        .lineSpacing(6)
                    Text("Yes / no / wait — without opening a thing.")
                        .font(HU.body())
                        .italic()
                        .foregroundStyle(HU.C.muted)
                }
                .padding(.horizontal, 32)

                Spacer()

                // sign-in section, anchored bottom
                VStack(alignment: .leading, spacing: 14) {
                    HairRule(label: "begin")
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
                    .clipShape(Capsule())

                    if let err = auth.lastError {
                        Text(err).font(HU.small()).foregroundStyle(HU.C.accent)
                    }

                    Text("继续即同意接收你授权的 agent 发送的交互通知。")
                        .font(HU.small())
                        .foregroundStyle(HU.C.muted)
                        .lineSpacing(2)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 40)
            }
        }
    }
}
