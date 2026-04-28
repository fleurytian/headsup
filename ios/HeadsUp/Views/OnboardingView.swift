import SwiftUI
import AuthenticationServices

struct OnboardingView: View {
    @EnvironmentObject var auth: AuthService
    @EnvironmentObject var push: PushService
    @EnvironmentObject var loc: Localizer

    var body: some View {
        ZStack {
            HU.C.bg.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Spacer().frame(height: 60)

                HStack {
                    Eyebrow(text: "headsup · md")
                    Spacer()
                    LanguageToggle()
                }
                .padding(.horizontal, 32)

                Spacer().frame(height: 14)

                Circle()
                    .fill(HU.C.accent)
                    .frame(width: 18, height: 18)
                    .padding(.horizontal, 32)

                Spacer().frame(height: 30)

                VStack(alignment: .leading, spacing: 12) {
                    LText(
                        "让你的 AI\n通过读 skill.md\n来给你提个醒。",
                        "Let your agents\ngive you a heads up\nby reading skill.md."
                    )
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundStyle(HU.C.ink)
                    .lineSpacing(6)

                    LText(
                        "Yes / No / Wait — 不用打开任何 App。",
                        "Yes / No / Wait — without opening a thing."
                    )
                    .font(HU.body())
                    .italic()
                    .foregroundStyle(HU.C.muted)
                }
                .padding(.horizontal, 32)

                Spacer()

                VStack(alignment: .leading, spacing: 14) {
                    HairRule(label: loc.lang == .zh ? "begin" : "begin")
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

                    LText(
                        "继续即同意接收你授权的 agent 发送的交互通知。",
                        "By continuing you accept interactive notifications from agents you authorize."
                    )
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

/// Small ZH / EN toggle pill — sits in top-right of any screen.
struct LanguageToggle: View {
    @EnvironmentObject var loc: Localizer
    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppLanguage.allCases, id: \.self) { l in
                Button { loc.set(l) } label: {
                    Text(l.label)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(0.5)
                        .foregroundStyle(loc.lang == l ? HU.C.bg : HU.C.muted)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(loc.lang == l ? HU.C.ink : Color.clear)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(HU.C.card))
        .overlay(Capsule().strokeBorder(HU.C.line, lineWidth: 1))
    }
}
