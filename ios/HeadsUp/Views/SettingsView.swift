import SwiftUI
import UIKit
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject var auth: AuthService
    @EnvironmentObject var push: PushService

    @State private var copied = false
    @State private var muteUntil: Date?
    @State private var muteLoading = false
    @State private var permissionStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        Form {
            // Permission recovery banner
            if permissionStatus == .denied {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("通知权限被关了", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.headline)
                        Text("HeadsUp 收不到任何 agent 的通知。去 iOS 设置 → HeadsUp → 通知，开「允许通知」。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("打开 iOS 设置") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("免打扰") {
                if let until = muteUntil, until > Date() {
                    HStack {
                        Image(systemName: "moon.zzz.fill").foregroundStyle(.purple)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("已静音").font(.body)
                            Text("到 \(until.formatted(date: .omitted, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("解除") { Task { await setMute(minutes: nil) } }
                            .disabled(muteLoading)
                    }
                } else {
                    Button {
                        Task { await setMute(minutes: 60) }
                    } label: {
                        Label("静音 1 小时", systemImage: "moon.zzz")
                    }
                    .disabled(muteLoading)
                    Button {
                        Task { await setMute(minutes: 8 * 60) }
                    } label: {
                        Label("静音 8 小时", systemImage: "bed.double")
                    }
                    .disabled(muteLoading)
                }
            }

            Section("账号") {
                if let session = auth.session {
                    HStack {
                        Text("User Key")
                        Spacer()
                        Text(session.userKey).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Button {
                        UIPasteboard.general.string = session.userKey
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Label(copied ? "已复制" : "复制 User Key", systemImage: "doc.on.doc")
                    }
                }
            }

            Section("通知") {
                HStack {
                    Text("权限")
                    Spacer()
                    Text(permissionLabel).foregroundStyle(permissionStatus == .authorized ? .green : .secondary)
                }
                if let token = push.deviceTokenString {
                    HStack {
                        Text("Device Token").font(.caption)
                        Spacer()
                        Text(token.prefix(8) + "…").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button("登出", role: .destructive) { auth.signOut() }
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refreshPermission()
            await refreshMute()
        }
    }

    private var permissionLabel: String {
        switch permissionStatus {
        case .authorized: return "已开启"
        case .denied: return "已拒绝"
        case .notDetermined: return "未设置"
        case .provisional: return "临时"
        case .ephemeral: return "临时"
        @unknown default: return "未知"
        }
    }

    private func refreshPermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        await MainActor.run { self.permissionStatus = settings.authorizationStatus }
    }

    private func refreshMute() async {
        guard let session = auth.session else { return }
        struct Me: Codable {
            let user_key: String
            let mute_until: Date?
        }
        do {
            let me: Me = try await APIClient.shared.get(
                "/v1/app/me", sessionToken: session.sessionToken
            )
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
                "/v1/app/mute",
                body: Body(minutes: minutes),
                sessionToken: session.sessionToken
            )
            self.muteUntil = resp.mute_until
        } catch {}
    }
}
