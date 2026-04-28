import SwiftUI

struct AgentPublic: Codable {
    let id: String
    let name: String
    let description: String?
    let logo_url: String?
}

struct AuthorizeView: View {
    @EnvironmentObject var deepLink: DeepLinkHandler
    let pending: DeepLinkHandler.PendingAuthorize

    @State private var agentInfo: AgentPublic?
    @State private var working = false
    @State private var loadingInfo = true
    @State private var error: String?
    @State private var done = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 24)

            // Avatar / icon
            Group {
                if done {
                    ZStack {
                        Circle().fill(.tint.opacity(0.15)).frame(width: 80, height: 80)
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.tint)
                    }
                } else if let url = agentInfo?.logo_url, let imgURL = URL(string: url) {
                    AsyncImage(url: imgURL) { phase in
                        switch phase {
                        case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
                        default:
                            ZStack { Circle().fill(.tint.opacity(0.15))
                                Image(systemName: "bell.badge.fill").font(.system(size: 32)).foregroundStyle(.tint) }
                        }
                    }
                    .frame(width: 80, height: 80)
                    .clipShape(Circle())
                } else {
                    ZStack {
                        Circle().fill(.tint.opacity(0.15)).frame(width: 80, height: 80)
                        Image(systemName: "bell.badge.fill").font(.system(size: 36)).foregroundStyle(.tint)
                    }
                }
            }

            VStack(spacing: 6) {
                Text(done ? "已连接" : (agentInfo?.name ?? (loadingInfo ? "加载中…" : "Agent")))
                    .font(.title2.bold())
                if !done {
                    Text(done ? "" : "想给你发交互式推送通知")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if !done, let desc = agentInfo?.description, !desc.isEmpty {
                Text(desc)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 8)
            }

            if !done {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("可以给你发带按钮的通知")
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("你的回应只会发回这个 Agent")
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.gray.opacity(0.5))
                        Text("看不到你的消息或其他 App")
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(.gray.opacity(0.5))
                        Text("随时可在主页左滑撤销授权")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
                .padding(.vertical, 10)
            }

            Spacer()

            if !done {
                VStack(spacing: 12) {
                    Button {
                        Task { await confirm() }
                    } label: {
                        if working {
                            ProgressView().tint(.white)
                        } else {
                            Text("授权").font(.headline).frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(working)

                    Button("取消") { deepLink.cancel() }
                        .disabled(working)
                }
                .padding(.horizontal, 32)
            } else {
                Button { deepLink.cancel() } label: {
                    Text("完成").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 32)
            }

            if let error = error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, 32)
            }

            Spacer().frame(height: 24)
        }
        .task { await loadAgentInfo() }
    }

    private func loadAgentInfo() async {
        loadingInfo = true
        defer { loadingInfo = false }
        do {
            let info: AgentPublic = try await APIClient.shared.get(
                "/v1/app/public/agents/\(pending.agentId)"
            )
            self.agentInfo = info
        } catch {
            // not fatal — fall back to placeholder
        }
    }

    private func confirm() async {
        working = true
        defer { working = false }
        do {
            try await deepLink.confirm(pending)
            await PushService.shared.refreshCategories()
            // First-auth tutorial push so the user learns long-press
            await sendTutorialPush()
            done = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// After authorizing, post a local notification that teaches the long-press gesture.
    private func sendTutorialPush() async {
        let content = UNMutableNotificationContent()
        content.title = "🎉 授权成功"
        content.body = "下次收到这种推送，长按它就能看到选项 ✓ / ✗"
        content.sound = .default
        if #available(iOS 15.0, *) { content.interruptionLevel = .active }
        // Use confirm_reject so the user can experiment with the long-press gesture
        content.categoryIdentifier = "confirm_reject"
        content.userInfo = ["message_id": "tutorial-\(UUID().uuidString)"]
        let req = UNNotificationRequest(
            identifier: "tutorial_\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1.5, repeats: false)
        )
        try? await UNUserNotificationCenter.current().add(req)
    }
}

import UserNotifications
