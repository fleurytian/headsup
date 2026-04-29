import SwiftUI
import UserNotifications

struct AgentPublic: Codable {
    let id: String
    let name: String
    let description: String?
    let logo_url: String?
    let agent_type: String?
}

struct AuthorizeView: View {
    @EnvironmentObject var deepLink: DeepLinkHandler
    @EnvironmentObject var loc: Localizer
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
                            HStack(spacing: 8) {
                                Eyebrow(text: done ? "connected" : "requests access")
                                if !done, let typeLabel = typeLabel {
                                    Text(typeLabel)
                                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                        .tracking(0.8)
                                        .foregroundStyle(HU.C.accent)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Capsule().fill(HU.C.accent.opacity(0.1)))
                                }
                            }
                            Text(done ? T("已授权", "Authorized")
                                      : (agentInfo?.name ?? (loadingInfo ? "..." : "Agent")))
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
                                permissionRow(allowed: true, zh: "可以给你发带按钮的通知",
                                              en: "Can send you actionable notifications")
                                permissionRow(allowed: true, zh: "你的回应只发回这个 Agent",
                                              en: "Your replies go only to this agent")
                                permissionRow(allowed: false, zh: "看不到你的消息或其他 App",
                                              en: "Cannot read your messages or other apps")
                                permissionRow(allowed: false, zh: "随时可在主页左滑撤销",
                                              en: "Revoke anytime by swiping left on home")
                            }
                        }
                    } else {
                        LText("通知会准时送达。\n你随时可以在主页里撤销它。",
                              "Notifications will arrive on time.\nYou can revoke this agent anytime from home.")
                            .font(HU.body())
                            .foregroundStyle(HU.C.muted)
                            .lineSpacing(4)
                    }

                    if let error = error {
                        Text(error).font(HU.small()).foregroundStyle(HU.C.accent)
                    }

                    Spacer().frame(height: 8)

                    if !done {
                        PrimaryButton(title: working ? "" : T("授权", "Authorize")) {
                            Task { await confirm() }
                        }
                        .overlay { if working { ProgressView().tint(HU.C.bg) } }
                        .disabled(working)

                        GhostButton(title: T("取消", "Cancel")) { deepLink.cancel() }
                            .disabled(working)
                    } else {
                        PrimaryButton(title: T("完成", "Done")) { deepLink.cancel() }
                    }

                    Spacer().frame(height: 12)
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
            }
        }
        .task { await loadAgentInfo() }
    }

    private var typeLabel: String? {
        guard let t = agentInfo?.agent_type else { return nil }
        // mirror the AGENT_TYPES dict in backend
        let map: [String: (String, String)] = [
            "assistant":  ("通用助手", "ASSISTANT"),
            "coding":     ("代码助手", "CODING"),
            "automation": ("自动化",   "AUTOMATION"),
            "monitor":    ("监控",     "MONITOR"),
            "companion":  ("伴侣",     "COMPANION"),
            "research":   ("研究",     "RESEARCH"),
            "other":      ("其他",     "OTHER"),
        ]
        guard let pair = map[t] else { return nil }
        return loc.lang == .zh ? pair.0 : pair.1
    }

    private var agentInitial: some View {
        Text(String((agentInfo?.name ?? "?").prefix(1)).uppercased())
            .font(HU.title(.heavy)).foregroundStyle(HU.C.accent)
    }

    private func permissionRow(allowed: Bool, zh: String, en: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: allowed ? "checkmark" : "xmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(allowed ? HU.C.ink : HU.C.muted.opacity(0.6))
                .frame(width: 16)
            LText(zh, en).font(HU.body())
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
        } catch APIError.http(410, _) {
            self.error = T("授权链接已过期。让 agent 重新发一个给你。",
                           "This authorization link has expired. Ask the agent to send a fresh one.")
        } catch APIError.http(404, _) {
            self.error = T("链接已被使用过或无效。让 agent 重新发一个。",
                           "Link already used or invalid. Ask the agent to send a fresh one.")
        } catch APIError.http(401, _), APIError.http(403, _) {
            self.error = T("登录过期了,请回到主页重新登录后再试。",
                           "Your sign-in expired — sign in again on the home screen, then retry.")
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func sendTutorialPush() async {
        let content = UNMutableNotificationContent()
        content.title = T("授权成功", "Authorized")
        content.body = T("下次收到这种推送,长按它就能看到选项。",
                         "Next time you get one of these — long-press to see the options.")
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
