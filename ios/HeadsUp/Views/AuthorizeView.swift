import SwiftUI
import UserNotifications

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
        ZStack {
            HU.C.bg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Spacer().frame(height: 8)

                    HStack(alignment: .center, spacing: 14) {
                        ZStack {
                            Circle().fill(done ? HU.C.ink : HU.C.accent.opacity(0.12))
                                .frame(width: 56, height: 56)
                            if done {
                                Image(systemName: "checkmark").font(.system(size: 22, weight: .bold))
                                    .foregroundStyle(HU.C.bg)
                            } else if let url = agentInfo?.logo_url, let imgURL = URL(string: url) {
                                AsyncImage(url: imgURL) { phase in
                                    switch phase {
                                    case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
                                    default: agentInitial
                                    }
                                }
                                .frame(width: 48, height: 48).clipShape(Circle())
                            } else {
                                agentInitial
                            }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Eyebrow(text: done ? "connected" : "requests access")
                            Text(done ? "已授权" : (agentInfo?.name ?? (loadingInfo ? "..." : "Agent")))
                                .font(HU.display())
                                .foregroundStyle(HU.C.ink)
                        }
                    }

                    if !done, let desc = agentInfo?.description, !desc.isEmpty {
                        Text(desc)
                            .font(HU.body())
                            .foregroundStyle(HU.C.muted)
                            .lineSpacing(4)
                    }

                    if !done {
                        VStack(alignment: .leading, spacing: 18) {
                            Eyebrow(text: "permissions")
                            VStack(alignment: .leading, spacing: 14) {
                                permissionRow(allowed: true, text: "可以给你发带按钮的通知")
                                permissionRow(allowed: true, text: "你的回应只发回这个 Agent")
                                permissionRow(allowed: false, text: "看不到你的消息或其他 App")
                                permissionRow(allowed: false, text: "随时可在主页左滑撤销")
                            }
                        }
                    } else {
                        Text("通知会准时送达。\n你随时可以在主页里撤销它。")
                            .font(HU.body())
                            .foregroundStyle(HU.C.muted)
                            .lineSpacing(4)
                    }

                    if let error = error {
                        Text(error).font(HU.small()).foregroundStyle(HU.C.accent)
                    }

                    Spacer().frame(height: 8)

                    if !done {
                        PrimaryButton(title: working ? "" : "授权", icon: working ? nil : nil) {
                            Task { await confirm() }
                        }
                        .overlay { if working { ProgressView().tint(HU.C.bg) } }
                        .disabled(working)

                        GhostButton(title: "取消") { deepLink.cancel() }
                            .disabled(working)
                    } else {
                        PrimaryButton(title: "完成") { deepLink.cancel() }
                    }

                    Spacer().frame(height: 12)
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
            }
        }
        .task { await loadAgentInfo() }
    }

    private var agentInitial: some View {
        Text(String((agentInfo?.name ?? "?").prefix(1)).uppercased())
            .font(HU.title(.heavy)).foregroundStyle(HU.C.accent)
    }

    private func permissionRow(allowed: Bool, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: allowed ? "checkmark" : "xmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(allowed ? HU.C.ink : HU.C.muted.opacity(0.6))
                .frame(width: 16)
            Text(text).font(HU.body())
                .foregroundStyle(allowed ? HU.C.ink : HU.C.muted)
        }
    }

    private func loadAgentInfo() async {
        loadingInfo = true
        defer { loadingInfo = false }
        do {
            let info: AgentPublic = try await APIClient.shared.get(
                "/v1/app/public/agents/\(pending.agentId)"
            )
            self.agentInfo = info
        } catch {}
    }

    private func confirm() async {
        working = true
        defer { working = false }
        do {
            try await deepLink.confirm(pending)
            await PushService.shared.refreshCategories()
            await sendTutorialPush()
            done = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func sendTutorialPush() async {
        let content = UNMutableNotificationContent()
        content.title = "授权成功"
        content.body = "下次收到这种推送，长按它就能看到选项。"
        content.sound = .default
        if #available(iOS 15.0, *) { content.interruptionLevel = .active }
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
