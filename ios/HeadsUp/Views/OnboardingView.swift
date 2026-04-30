import SwiftUI
import AuthenticationServices

struct OnboardingView: View {
    @EnvironmentObject var auth: AuthService
    @EnvironmentObject var push: PushService
    @EnvironmentObject var loc: Localizer

    /// Map ASAuthorizationError codes to a sentence the user can act on
    /// instead of "The operation couldn't be completed (1001)".
    private func friendlyAppleError(_ error: Error) -> String {
        let ns = error as NSError
        if let code = ASAuthorizationError.Code(rawValue: ns.code) {
            switch code {
            case .canceled:
                return T(
                    "你取消了登录。再点一次按钮就能继续。",
                    "You canceled. Tap the button to try again."
                )
            case .invalidResponse:
                return T(
                    "Apple 返回意外的响应,请稍后再试一次。",
                    "Apple returned an unexpected response. Try again in a moment."
                )
            case .notHandled:
                return T(
                    "这台设备暂时无法登录,请稍后重试或检查 Apple ID 设置。",
                    "Apple Sign-In couldn't complete here. Try again or check your Apple ID settings."
                )
            case .failed:
                return T(
                    "登录失败,请检查网络后重试。",
                    "Sign-in failed. Check your network and try again."
                )
            case .notInteractive:
                return T(
                    "需要先点一下登录按钮。",
                    "Tap the Sign in button to continue."
                )
            default:
                // Includes .unknown, .matchedExcludedCredential (iOS 17.4+),
                // .credentialImport / .credentialExport (iOS 18+), and any
                // future cases — fall through to the OS-localized message.
                break
            }
        }
        return error.localizedDescription
    }

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
                        self.auth.prepareRequest(request)
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
                            self.auth.lastError = self.friendlyAppleError(error)
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
