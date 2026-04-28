import SwiftUI
import UIKit
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject var auth: AuthService
    @EnvironmentObject var push: PushService
    @EnvironmentObject var loc: Localizer

    @State private var copied = false
    @State private var muteUntil: Date?
    @State private var muteLoading = false
    @State private var permissionStatus: UNAuthorizationStatus = .notDetermined

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
                                SettingsKeyValue(key: "user key", value: session.userKey, mono: true)
                                Rectangle().fill(HU.C.line).frame(height: 1).padding(.leading, 16)
                                Button {
                                    UIPasteboard.general.string = session.userKey
                                    copied = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                                } label: {
                                    HStack {
                                        Text(copied ? T("已复制", "Copied") : T("复制 User Key", "Copy User Key"))
                                            .font(HU.body()).foregroundStyle(HU.C.accent)
                                        Spacer()
                                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(HU.C.accent)
                                    }
                                    .padding(.horizontal, 16).padding(.vertical, 14)
                                }
                            }
                        }
                        .card()
                    }

                    SettingsSection(title: "notifications") {
                        VStack(alignment: .leading, spacing: 0) {
                            SettingsKeyValue(
                                key: "permission",
                                value: permissionLabel,
                                valueColor: permissionStatus == .authorized ? HU.C.ink : HU.C.muted
                            )
                            if let token = push.deviceTokenString {
                                Rectangle().fill(HU.C.line).frame(height: 1).padding(.leading, 16)
                                SettingsKeyValue(key: "device token", value: String(token.prefix(12)) + "…", mono: true)
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

                    Spacer().frame(height: 40)
                }
                .padding(.vertical, 12)
            }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Settings")
                    .font(HU.title(.bold))
                    .foregroundStyle(HU.C.ink)
            }
        }
        .toolbarBackground(HU.C.bg, for: .navigationBar)
        .task {
            await refreshPermission()
            await refreshMute()
        }
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
