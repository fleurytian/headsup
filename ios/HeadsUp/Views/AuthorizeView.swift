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
                VStack(spacing: 22) {
                    Spacer().frame(height: 8)

                    // Avatar / icon
                    ZStack {
                        Circle().fill(HU.pastelGradient.opacity(done ? 0.85 : 0.4))
                            .frame(width: 100, height: 100)
                        if done {
                            Image(systemName: "checkmark").font(.system(size: 40, weight: .bold))
                                .foregroundStyle(.white)
                        } else if let url = agentInfo?.logo_url, let imgURL = URL(string: url) {
                            AsyncImage(url: imgURL) { phase in
                                switch phase {
                                case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
                                default: Text("✦").font(.system(size: 36)).foregroundStyle(.white)
                                }
                            }
                            .frame(width: 86, height: 86).clipShape(Circle())
                        } else {
                            Text(HU.star).font(.system(size: 40)).foregroundStyle(.white)
                        }
                    }

                    VStack(spacing: 6) {
                        Text(done ? "CONNECTED" : (agentInfo?.name ?? (loadingInfo ? "..." : "AGENT")))
                            .font(HU.rounded(22, weight: .heavy)).tracking(done ? 6 : 1)
                            .foregroundStyle(HU.C.ink)
                        if !done {
                            Text("\(HU.diamond)  REQUESTS  ACCESS  \(HU.diamond)")
                                .font(HU.mono(10, weight: .medium)).tracking(3)
                                .foregroundStyle(HU.C.lavender)
                        }
                    }

                    if !done, let desc = agentInfo?.description, !desc.isEmpty {
                        Text(desc)
                            .font(HU.rounded(13))
                            .foregroundStyle(HU.C.muted)
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                            .padding(.horizontal, 28)
                    }

                    if !done {
                        VStack(alignment: .leading, spacing: 12) {
                            permissionRow(icon: "checkmark.circle.fill", color: HU.C.mint,
                                text: "可以给你发带按钮的通知")
                            permissionRow(icon: "checkmark.circle.fill", color: HU.C.mint,
                                text: "你的回应只发回这个 Agent")
                            permissionRow(icon: "xmark.circle.fill", color: HU.C.muted.opacity(0.5),
                                text: "看不到你的消息或其他 App")
                            permissionRow(icon: "arrow.uturn.backward.circle.fill", color: HU.C.muted.opacity(0.5),
                                text: "随时可在主页左滑撤销")
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .vaporCard()
                        .padding(.horizontal, 20)
                    } else {
                        Text("you're set\n通知准时送达")
                            .font(HU.rounded(13))
                            .multilineTextAlignment(.center)
                            .lineSpacing(4)
                            .foregroundStyle(HU.C.muted)
                            .padding(.top, 8)
                    }

                    if let error = error {
                        Text(error).font(HU.mono(11)).foregroundStyle(HU.C.pink)
                            .padding(.horizontal, 32)
                    }

                    Spacer().frame(height: 8)

                    if !done {
                        VaporButton(title: working ? "" : "授权",
                                    icon: working ? nil : "sparkles",
                                    primary: true) {
                            Task { await confirm() }
                        }
                        .disabled(working)
                        .overlay { if working { ProgressView().tint(.white) } }
                        .padding(.horizontal, 28)

                        VaporButton(title: "取消", primary: false) { deepLink.cancel() }
                            .disabled(working)
                            .padding(.horizontal, 28)
                    } else {
                        VaporButton(title: "完成", icon: "heart.fill", primary: true) {
                            deepLink.cancel()
                        }
                        .padding(.horizontal, 28)
                    }

                    Spacer().frame(height: 12)
                }
                .padding(.top, 16)
            }
        }
        .task { await loadAgentInfo() }
    }

    private func permissionRow(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(HU.rounded(13)).foregroundStyle(HU.C.ink)
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
        content.title = "🎉 授权成功"
        content.body = "下次收到这种推送，长按它就能看到选项 ✓ / ✗"
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
