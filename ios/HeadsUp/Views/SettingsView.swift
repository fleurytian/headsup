import SwiftUI
import UIKit
import StoreKit
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject var auth: AuthService
    @EnvironmentObject var push: PushService
    @EnvironmentObject var loc: Localizer

    @State private var copied = false
    @State private var deviceTokenCopied = false
    @State private var muteUntil: Date?
    @State private var muteLoading = false
    @State private var permissionStatus: UNAuthorizationStatus = .notDetermined
    @State private var showDeleteConfirm = false
    @State private var deleting = false
    @State private var deleteError: String?

    var body: some View {
        ZStack {
            HU.C.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Spacer().frame(height: 4)

                    // Language picker — first thing
                    SettingsSection(title: "language") {
                        HStack(spacing: 10) {
                            ForEach(AppLanguage.allCases, id: \.self) { l in
                                Button { loc.set(l) } label: {
                                    Text(l.label)
                                        .font(HU.body(.medium))
                                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                                        .foregroundStyle(loc.lang == l ? HU.C.bg : HU.C.ink)
                                        .background(
                                            Capsule().fill(loc.lang == l ? HU.C.ink : Color.clear)
                                        )
                                        .overlay(
                                            Capsule().strokeBorder(HU.C.ink, lineWidth: loc.lang == l ? 0 : 1)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Permission banner if denied
                    if permissionStatus == .denied {
                        VStack(alignment: .leading, spacing: 10) {
                            Eyebrow(text: "warning", color: HU.C.accent)
                            LText("通知权限被关了。HeadsUp 现在收不到任何 agent 的通知。",
                                  "Notification permission is off. HeadsUp can't deliver any agent's pushes right now.")
                                .font(HU.body()).foregroundStyle(HU.C.ink)
                                .lineSpacing(3)
                            Button {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            } label: {
                                Text(T("打开 iOS 设置", "Open iOS Settings"))
                                    .font(HU.small(.semibold))
                                    .foregroundStyle(HU.C.bg)
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(Capsule().fill(HU.C.ink))
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                        .padding(.horizontal, 20)
                    }

                    SettingsSection(title: "do not disturb") {
                        if let until = muteUntil, until > Date() {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    LText("已静音", "Muted").font(HU.body(.medium)).foregroundStyle(HU.C.ink)
                                    Text("\(T("到", "until")) \(until.formatted(date: .omitted, time: .shortened))")
                                        .font(HU.small()).foregroundStyle(HU.C.muted)
                                }
                                Spacer()
                                Button(T("解除", "Unmute")) { Task { await setMute(minutes: nil) } }
                                    .font(HU.small(.semibold))
                                    .foregroundStyle(HU.C.accent)
                                    .disabled(muteLoading)
                            }
                            .padding(16).card()
                        } else {
                            HStack(spacing: 10) {
                                MuteButton(title: T("1 小时", "1 hour"), min: 60, action: setMute)
                                MuteButton(title: T("8 小时", "8 hours"), min: 8 * 60, action: setMute)
                            }
                        }
                    }

                    SettingsSection(title: "account") {
                        VStack(alignment: .leading, spacing: 0) {
                            if let session = auth.session {
                                // The whole user-key row is the copy button —
                                // tap anywhere on it to copy. Codex review:
                                // "the separate Copy button felt redundant
                                // when the value itself was right there."
                                Button {
                                    UIPasteboard.general.string = session.userKey
                                    copied = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                                } label: {
                                    SettingsKeyValue(
                                        key: copied ? T("已复制 user key", "user key copied") : "user key",
                                        value: session.userKey,
                                        valueColor: copied ? HU.C.accent : HU.C.muted,
                                        mono: true
                                    )
                                }
                                .buttonStyle(.plain)
                                Rectangle().fill(HU.C.line).frame(height: 1).padding(.leading, 16)
                            }
                            // Permissions + device-token consolidated into
                            // the account section: they're all "what
                            // identity / channel does HeadsUp have for me"
                            // pieces, not separate concerns.
                            SettingsKeyValue(
                                key: T("通知权限", "notifications"),
                                value: permissionLabel,
                                valueColor: permissionStatus == .authorized ? HU.C.ink : HU.C.muted
                            )
                            if let token = push.deviceTokenString {
                                Rectangle().fill(HU.C.line).frame(height: 1).padding(.leading, 16)
                                Button {
                                    UIPasteboard.general.string = token
                                    deviceTokenCopied = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { deviceTokenCopied = false }
                                } label: {
                                    SettingsKeyValue(
                                        key: deviceTokenCopied
                                            ? T("已复制 device token", "device token copied")
                                            : T("设备 token (APNs)", "device token (APNs)"),
                                        value: String(token.prefix(12)) + "…",
                                        valueColor: deviceTokenCopied ? HU.C.accent : HU.C.muted,
                                        mono: true
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .card()
                    }
                    // Diagnose + the Demo Push button live together as the
                    // "is everything wired up" check pair: Diagnose tells
                    // you what state you're in; Demo Push is the live
                    // round-trip test of that state.
                    SettingsSection(title: "diagnostics") {
                        VStack(alignment: .leading, spacing: 0) {
                            DemoPushButton()
                            Rectangle().fill(HU.C.line).frame(height: 1).padding(.leading, 16)
                            NavigationLink(destination: DiagnoseView()) {
                                settingsRow(zh: "诊断", en: "Diagnose", icon: "stethoscope")
                            }
                        }
                        .card()
                    }
                    // Badges + Stats moved to ProfileView (bottom dock → 我的)
                    // — they're identity / engagement surfaces, not system
                    // configuration, so they don't belong in Settings.

                    TipJarSection()

                    SettingsSection(title: "about") {
                        VStack(alignment: .leading, spacing: 0) {
                            SettingsKeyValue(key: "version", value: HU.versionString)
                            Rectangle().fill(HU.C.line).frame(height: 1).padding(.leading, 16)
                            Link(destination: URL(string: "https://headsup.md")!) {
                                HStack {
                                    LText("项目主页", "Project page")
                                        .font(HU.body()).foregroundStyle(HU.C.ink)
                                    Spacer()
                                    Text("headsup.md").font(HU.small()).foregroundStyle(HU.C.muted)
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(HU.C.muted)
                                }
                                .padding(.horizontal, 16).padding(.vertical, 14)
                            }
                            Rectangle().fill(HU.C.line).frame(height: 1).padding(.leading, 16)
                            Link(destination: URL(string: "https://github.com/fleurytian/headsup")!) {
                                HStack {
                                    LText("源码 (GitHub)", "Source on GitHub")
                                        .font(HU.body()).foregroundStyle(HU.C.ink)
                                    Spacer()
                                    Text("github.com/fleurytian/headsup")
                                        .font(HU.small()).foregroundStyle(HU.C.muted)
                                        .lineLimit(1).truncationMode(.middle)
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(HU.C.muted)
                                }
                                .padding(.horizontal, 16).padding(.vertical, 14)
                            }
                            Rectangle().fill(HU.C.line).frame(height: 1).padding(.leading, 16)
                            Link(destination: URL(string: "https://headsup.md/privacy")!) {
                                HStack {
                                    LText("隐私政策", "Privacy Policy")
                                        .font(HU.body()).foregroundStyle(HU.C.ink)
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(HU.C.muted)
                                }
                                .padding(.horizontal, 16).padding(.vertical, 14)
                            }
                            Rectangle().fill(HU.C.line).frame(height: 1).padding(.leading, 16)
                            Link(destination: URL(string: "mailto:fleurytian@gmail.com")!) {
                                HStack {
                                    LText("联系我们", "Contact")
                                        .font(HU.body()).foregroundStyle(HU.C.ink)
                                    Spacer()
                                    Text("fleurytian@gmail.com").font(HU.small()).foregroundStyle(HU.C.muted)
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(HU.C.muted)
                                }
                                .padding(.horizontal, 16).padding(.vertical, 14)
                            }
                        }
                        .card()
                    }

                    Button(role: .destructive) {
                        auth.signOut()
                    } label: {
                        HStack {
                            Spacer()
                            LText("登出", "Sign out").font(HU.body(.medium)).foregroundStyle(HU.C.accent)
                            Spacer()
                        }
                        .padding(.vertical, 14)
                        .background(Capsule().strokeBorder(HU.C.accent, lineWidth: 1))
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        HStack {
                            Spacer()
                            LText("删除账号", "Delete account")
                                .font(HU.small(.medium))
                                .foregroundStyle(HU.C.muted)
                            Spacer()
                        }
                        .padding(.vertical, 10)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .disabled(deleting)

                    if let deleteError = deleteError {
                        Text(deleteError)
                            .font(HU.small())
                            .foregroundStyle(HU.C.accent)
                            .padding(.horizontal, 20)
                    }

                    Spacer().frame(height: 40)
                }
                .padding(.vertical, 12)
            }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .principal) { BrandedTitleBar() }
        }
        .toolbarBackground(HU.C.bg, for: .navigationBar)
        .task {
            await refreshPermission()
            await refreshMute()
        }
        .alert(T("删除账号?", "Delete account?"), isPresented: $showDeleteConfirm) {
            Button(T("取消", "Cancel"), role: .cancel) {
                // Cold Feet badge — they thought about it, didn't do it.
                Task { await coldFeet() }
            }
            Button(T("永久删除", "Delete permanently"), role: .destructive) {
                Task { await deleteAccount() }
            }
        } message: {
            LText(
                "这会永久删除你的账号、所有 agent 授权、推送历史。无法恢复。",
                "This permanently removes your account, every agent authorization, and your push history. Cannot be undone."
            )
        }
    }

    private func deleteAccount() async {
        guard let session = auth.session else { return }
        deleting = true
        defer { deleting = false }
        do {
            try await APIClient.shared.delete("/v1/app/me", sessionToken: session.sessionToken)
            auth.signOut()
        } catch {
            deleteError = error.localizedDescription
        }
    }

    private func coldFeet() async {
        guard let session = auth.session else { return }
        struct Empty: Encodable {}
        struct R: Decodable {}
        do {
            let _: R = try await APIClient.shared.post(
                "/v1/app/me/cold-feet", body: Empty(), sessionToken: session.sessionToken
            )
        } catch {}
    }

    private var permissionLabel: String {
        switch permissionStatus {
        case .authorized: return T("已开启", "Granted")
        case .denied: return T("已拒绝", "Denied")
        case .notDetermined: return T("未设置", "Not set")
        case .provisional, .ephemeral: return T("临时", "Provisional")
        @unknown default: return "?"
        }
    }

    private func refreshPermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        await MainActor.run { self.permissionStatus = settings.authorizationStatus }
    }

    private func refreshMute() async {
        guard let session = auth.session else { return }
        struct Me: Codable { let user_key: String; let mute_until: Date? }
        do {
            let me: Me = try await APIClient.shared.get("/v1/app/me", sessionToken: session.sessionToken)
            self.muteUntil = me.mute_until
        } catch {}
    }

    private func setMute(minutes: Int?) async {
        guard let session = auth.session else { return }
        muteLoading = true
        defer { muteLoading = false }
        struct Body: Codable { let minutes: Int? }
        struct Resp: Codable { let mute_until: Date? }
        do {
            let resp: Resp = try await APIClient.shared.post(
                "/v1/app/mute", body: Body(minutes: minutes), sessionToken: session.sessionToken)
            self.muteUntil = resp.mute_until
        } catch {}
    }
}

/// Tappable nav row used by the You / About sections.
@ViewBuilder
fileprivate func settingsRow(zh: String, en: String, icon: String) -> some View {
    HStack(spacing: 12) {
        Image(systemName: icon).font(.callout).foregroundStyle(HU.C.accent).frame(width: 22)
        LText(zh, en).font(HU.body()).foregroundStyle(HU.C.ink)
        Spacer()
        Image(systemName: "chevron.right").font(.caption.weight(.medium)).foregroundStyle(HU.C.muted.opacity(0.7))
    }
    .padding(.horizontal, 16).padding(.vertical, 14)
    .contentShape(Rectangle())
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: title).padding(.horizontal, 20)
            content.padding(.horizontal, 20)
        }
    }
}

private struct SettingsKeyValue: View {
    let key: String
    let value: String
    var valueColor: Color = HU.C.ink
    var mono: Bool = false
    var body: some View {
        HStack {
            Text(key).font(HU.small()).foregroundStyle(HU.C.muted)
            Spacer()
            Text(value)
                .font(mono ? .system(size: 12, design: .monospaced) : HU.small(.medium))
                .foregroundStyle(valueColor)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }
}

/// "Send myself a test notification." Hits POST /v1/app/me/demo-push, which
/// auto-binds a server-side "HeadsUp Demo" agent if not already bound and
/// fires one confirm_reject push back to this device. Lets a brand-new user
/// (or App Store reviewer) walk through the full lock-screen reply flow
/// without needing to set up an external agent first.
private struct DemoPushButton: View {
    @State private var sending = false
    @State private var status: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Task { await fire() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: sending ? "hourglass" : "bell.badge.fill")
                        .font(.body.weight(.medium))
                        .foregroundStyle(HU.C.accent)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        LText("给我自己发一条测试通知",
                              "Send myself a test notification")
                            .font(HU.body(.medium)).foregroundStyle(HU.C.ink)
                        LText("用来熟悉锁屏长按回复的体验。",
                              "Walks you through the lock-screen reply flow.")
                            .font(HU.small()).foregroundStyle(HU.C.muted)
                    }
                    Spacer()
                    if sending {
                        ProgressView().scaleEffect(0.7).tint(HU.C.muted)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
            }
            .buttonStyle(.plain)
            .disabled(sending)

            if let s = status {
                Text(s)
                    .font(HU.small())
                    .foregroundStyle(HU.C.muted)
                    .padding(.horizontal, 16).padding(.bottom, 12)
            }
        }
    }

    private func fire() async {
        guard let session = AuthService.shared.session else { return }
        sending = true
        defer { sending = false }
        status = nil
        struct Empty: Encodable {}
        struct Resp: Decodable {
            let status: String?
            let agent_name: String?
        }
        do {
            let resp: Resp = try await APIClient.shared.post(
                "/v1/app/me/demo-push",
                body: Empty(),
                sessionToken: session.sessionToken
            )
            status = T(
                "已发送 — 几秒后到 \"\(resp.agent_name ?? "HeadsUp Demo")\" 名下,锁屏长按试试。",
                "Sent — within a few seconds you'll get one from \"\(resp.agent_name ?? "HeadsUp Demo")\". Long-press to reply."
            )
        } catch {
            status = T(
                "发送失败: \(error.localizedDescription)",
                "Failed: \(error.localizedDescription)"
            )
        }
    }
}

/// Three-tier StoreKit IAP tip jar. Apple takes 15-30%, but the in-app
/// purchase path is one tap and auto-awards the Supporter badge without
/// an email roundtrip — for users who just want to drop a tip and move on.
struct TipJarSection: View {
    @StateObject private var tipJar = TipJarService.shared
    @EnvironmentObject var loc: Localizer

    var body: some View {
        SettingsSection(title: "tip jar") {
            VStack(alignment: .leading, spacing: 0) {
                if tipJar.products.isEmpty {
                    Text(loc.lang == .zh
                         ? "Tip jar 暂时无法加载 — 网络问题或者还没在 App Store Connect 配置 IAP 商品。"
                         : "Tip jar unavailable — likely a network issue or IAP products not yet configured in App Store Connect.")
                        .font(HU.small())
                        .foregroundStyle(HU.C.muted)
                        .padding(.horizontal, 16).padding(.vertical, 14)
                } else {
                    LText("一键打赏 — Supporter 徽章自动到账。",
                          "One-tap tip — the Supporter badge unlocks automatically.")
                        .font(HU.small())
                        .foregroundStyle(HU.C.muted)
                        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
                    HStack(spacing: 8) {
                        ForEach(tipJar.products, id: \.id) { p in
                            TipButton(product: p,
                                      busy: tipJar.purchasingID == p.id) {
                                Task { await tipJar.purchase(p) }
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 12)
                    if tipJar.thanked {
                        Text("💝 " + (loc.lang == .zh ? "谢谢你!" : "Thank you!"))
                            .font(HU.small(.semibold))
                            .foregroundStyle(HU.C.accent)
                            .padding(.horizontal, 16).padding(.bottom, 12)
                    }
                }
            }
            .card()
        }
    }
}

private struct TipButton: View {
    let product: Product
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(product.displayPrice)
                    .font(HU.body(.semibold))
                    .foregroundStyle(HU.C.ink)
                Text(product.displayName.isEmpty ? product.id : product.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(HU.C.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Capsule().strokeBorder(HU.C.ink, lineWidth: 1))
            .overlay {
                if busy { ProgressView().scaleEffect(0.7).tint(HU.C.muted) }
            }
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }
}

private struct MuteButton: View {
    let title: String
    let min: Int
    let action: (Int?) async -> Void
    var body: some View {
        Button {
            Task { await action(min) }
        } label: {
            HStack {
                Image(systemName: "moon").font(.caption.weight(.medium))
                Text(title).font(HU.body(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(HU.C.ink)
            .background(Capsule().strokeBorder(HU.C.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
