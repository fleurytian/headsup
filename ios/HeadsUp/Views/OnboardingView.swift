import SwiftUI
import AuthenticationServices

struct OnboardingView: View {
    @EnvironmentObject var auth: AuthService
    @EnvironmentObject var push: PushService

    var body: some View {
        ZStack {
            HU.C.bg.ignoresSafeArea()

            // Top decorative gradient sun + grid feel
            VStack(spacing: 0) {
                ZStack(alignment: .center) {
                    // sun
                    Circle()
                        .fill(HU.sunsetGradient)
                        .frame(width: 220, height: 220)
                        .blur(radius: 0.5)
                        .opacity(0.85)
                    // wireframe grid behind sun
                    GeometryReader { geo in
                        Path { p in
                            let count = 6
                            for i in 0...count {
                                let y = geo.size.height * CGFloat(i) / CGFloat(count)
                                p.move(to: .init(x: 0, y: y))
                                p.addLine(to: .init(x: geo.size.width, y: y))
                            }
                        }
                        .stroke(HU.C.lavender.opacity(0.25), style: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
                    }
                    .frame(height: 220)
                    .mask(
                        LinearGradient(colors: [.clear, .black, .clear],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                }
                .frame(height: 280)
                Spacer()
            }
            .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer().frame(height: 200)

                // Wordmark — wide tracking, retro feel
                VStack(spacing: 6) {
                    Text("H E A D S U P")
                        .font(HU.rounded(34, weight: .heavy))
                        .tracking(8)
                        .foregroundStyle(HU.C.ink)
                    Text("\(HU.diamond)  AGENT × HUMAN  \(HU.diamond)")
                        .font(HU.mono(11, weight: .medium))
                        .tracking(3)
                        .foregroundStyle(HU.C.lavender)
                }

                Text("让你的 AI 能在通知栏跟你说话\nSay yes / no — without opening anything.")
                    .font(HU.rounded(15, weight: .regular))
                    .foregroundStyle(HU.C.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 36)

                Spacer()

                VStack(spacing: 14) {
                    // Sign in with Apple — keep system component, wrap in retro frame
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
                    .frame(height: 52)
                    .clipShape(Capsule())
                    .padding(.horizontal, 32)

                    if let err = auth.lastError {
                        Text(err)
                            .font(HU.mono(11))
                            .foregroundStyle(HU.C.pink)
                            .padding(.horizontal, 32)
                    }
                }

                Text("By continuing you accept interactive notifications\nfrom agents you authorize.")
                    .font(HU.mono(10))
                    .tracking(0.5)
                    .foregroundStyle(HU.C.muted.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.horizontal, 36)
                    .padding(.bottom, 24)
            }
        }
    }
}
