import SwiftUI
import UserNotifications

/// Settings → 诊断 / Diagnose. One-page report of "is everything that
/// has to work for HeadsUp to deliver a push, working?"
struct DiagnosePayload: Codable {
    let user_key: String
    let has_apns_token: Bool
    let muted_until: Date?
    let active_bindings: Int
    let session_ok: Bool
    let server_time: String
}

struct DiagnoseView: View {
    @EnvironmentObject var auth: AuthService
    @EnvironmentObject var loc: Localizer
    @StateObject private var status = StatusMonitor.shared
    @State private var payload: DiagnosePayload?
    @State private var loading = false
    @State private var notifAuth: UNAuthorizationStatus = .notDetermined

    var body: some View {
        ZStack {
            HU.C.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Spacer().frame(height: 4)
                    intro
                    if let p = payload {
                        checkRow(ok: p.session_ok,
                                 zh: "登录状态有效", en: "Session valid")
                        checkRow(ok: p.has_apns_token,
                                 zh: "iPhone 已注册到 APNs", en: "Device registered with APNs",
                                 hint: T("如果不是, 切换到 5G 然后重新打开 app 一次", "If not, toggle cellular off+on and reopen the app"))
                        checkRow(ok: notifAuth == .authorized || notifAuth == .provisional,
                                 zh: "通知权限已开", en: "Notifications allowed")
                        checkRow(ok: status.isOnline,
                                 zh: "现在有网络", en: "Network reachable")
                        checkRow(ok: p.active_bindings > 0,
                                 zh: "至少有一个 agent 授权", en: "At least one agent authorized",
                                 hint: T("没 agent 没人能给你发", "no agent = no one to push you"))
                        checkRow(ok: p.muted_until == nil || p.muted_until! < Date(),
                                 zh: "未设勿扰", en: "Not in DND")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(T("user_key", "user_key"))
                                .font(HU.eyebrow()).tracking(1.2).foregroundStyle(HU.C.muted)
                            Text(p.user_key)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(HU.C.ink)
                                .textSelection(.enabled)
                        }
                        .padding(14).card()
                        .padding(.horizontal, 16)
                    } else if loading {
                        ProgressView().tint(HU.C.muted).frame(maxWidth: .infinity).padding(40)
                    }

                    Button {
                        Task { await load() }
                    } label: {
                        HStack {
                            Spacer()
                            Text(T("再跑一次", "Run again"))
                                .font(HU.body(.medium)).foregroundStyle(HU.C.bg)
                            Spacer()
                        }
                        .padding(.vertical, 14)
                        .background(Capsule().fill(HU.C.ink))
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    Spacer().frame(height: 40)
                }
                .padding(.vertical, 12)
            }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(T("诊断", "Diagnose")).font(HU.title(.bold)).foregroundStyle(HU.C.ink)
            }
        }
        .toolbarBackground(HU.C.bg, for: .navigationBar)
        .task { await load() }
    }

    private var intro: some View {
        LText(
            "如果你 agent 没收到推送, 这一页帮你排查。",
            "If pushes aren't arriving, this page tells you why."
        )
        .font(HU.body()).foregroundStyle(HU.C.muted).lineSpacing(3)
        .padding(.horizontal, 24)
        .padding(.bottom, 4)
    }

    private func checkRow(ok: Bool, zh: String, en: String, hint: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? HU.C.accent : HU.C.accent)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                LText(zh, en).font(HU.body()).foregroundStyle(HU.C.ink)
                if !ok, let h = hint {
                    Text(h).font(HU.small()).foregroundStyle(HU.C.muted)
                }
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(HU.C.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(HU.C.line, lineWidth: 1))
        .padding(.horizontal, 16)
    }

    private func load() async {
        guard let session = auth.session else { return }
        loading = true; defer { loading = false }
        do {
            payload = try await APIClient.shared.get(
                "/v1/app/me/diagnose", sessionToken: session.sessionToken
            )
        } catch {}
        let s = await UNUserNotificationCenter.current().notificationSettings()
        notifAuth = s.authorizationStatus
    }
}
