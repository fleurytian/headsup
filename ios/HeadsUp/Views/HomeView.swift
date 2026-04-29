import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject var auth: AuthService
    @EnvironmentObject var deepLink: DeepLinkHandler
    @EnvironmentObject var loc: Localizer
    @StateObject private var status = StatusMonitor.shared
    @State private var bindings: [AgentBinding] = []
    @State private var loading = false
    @State private var error: String?
    @State private var showAddAgent = false

    var body: some View {
        NavigationStack {
            ZStack {
                HU.C.bg.ignoresSafeArea()

                if bindings.isEmpty && !loading {
                    EmptyAgentsView(showAddAgent: $showAddAgent)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(status.activeIssues, id: \.self) { issue in
                                StatusBanner(issue: issue).padding(.horizontal, 16)
                            }
                            HStack {
                                Eyebrow(text: "agents · \(bindings.count)")
                                Spacer()
                            }
                            .padding(.horizontal, 24)

                            VStack(spacing: 0) {
                                ForEach(Array(bindings.enumerated()), id: \.element.id) { idx, agent in
                                    NavigationLink(destination: AgentDetailView(binding: agent)) {
                                        AgentRow(binding: agent)
                                    }
                                    .buttonStyle(.plain)
                                    .swipeActions(edge: .trailing) {
                                        Button(T("撤销", "Revoke"), role: .destructive) {
                                            Task { await revoke(agent) }
                                        }
                                    }
                                    if idx < bindings.count - 1 {
                                        Rectangle().fill(HU.C.line).frame(height: 1)
                                            .padding(.leading, 24)
                                    }
                                }
                            }
                            .background(HU.C.card)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(HU.C.line, lineWidth: 1)
                            )
                            .padding(.horizontal, 16)

                            HStack(spacing: 6) {
                                Spacer()
                                Image(systemName: "arrow.down").font(.caption2)
                                LText("拉下来刷新", "Pull to refresh")
                                    .font(HU.small())
                                Spacer()
                            }
                            .foregroundStyle(HU.C.muted)
                            .padding(.top, 4)
                        }
                        .padding(.vertical, 16)
                    }
                }
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showAddAgent = true } label: {
                        Image(systemName: "plus")
                            .font(.headline)
                            .foregroundStyle(HU.C.ink)
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text("HeadsUp")
                        .font(HU.title(.bold))
                        .foregroundStyle(HU.C.ink)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 18) {
                        NavigationLink {
                            HistoryView()
                        } label: {
                            Image(systemName: "clock")
                                .font(.headline)
                                .foregroundStyle(HU.C.ink)
                        }
                        NavigationLink {
                            SettingsView()
                        } label: {
                            Image(systemName: "person")
                                .font(.headline)
                                .foregroundStyle(HU.C.ink)
                        }
                    }
                }
            }
            .toolbarBackground(HU.C.bg, for: .navigationBar)
            .refreshable { await loadBindings() }
            .task { await loadBindings() }
            .onChange(of: deepLink.pendingAuthorize?.id) { _ in
                Task { await loadBindings() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                Task { await loadBindings() }
            }
            .sheet(isPresented: $showAddAgent) {
                AddAgentView()
            }
        }
    }

    private func loadBindings() async {
        guard let session = auth.session else { return }
        loading = true
        defer { loading = false }
        do {
            let result: [AgentBinding] = try await APIClient.shared.get(
                "/v1/app/bindings",
                sessionToken: session.sessionToken
            )
            self.bindings = result
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func revoke(_ agent: AgentBinding) async {
        guard let session = auth.session else { return }
        do {
            try await APIClient.shared.delete(
                "/v1/app/bindings/\(agent.agentId)",
                sessionToken: session.sessionToken
            )
            bindings.removeAll { $0.id == agent.id }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct AgentRow: View {
    let binding: AgentBinding
    @EnvironmentObject var loc: Localizer

    private var subtitle: String {
        if let last = binding.lastMessageAt {
            let fmt = RelativeDateTimeFormatter()
            fmt.unitsStyle = .abbreviated
            return T(
                "活跃于 \(fmt.localizedString(for: last, relativeTo: Date()))",
                "active \(fmt.localizedString(for: last, relativeTo: Date()))"
            )
        }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return T(
            "授权于 \(fmt.localizedString(for: binding.boundAt, relativeTo: Date()))",
            "authorized \(fmt.localizedString(for: binding.boundAt, relativeTo: Date()))"
        )
    }

    var body: some View {
        HStack(spacing: 14) {
            // Real logo when the agent set one; otherwise initial-on-accent.
            ZStack {
                Circle().fill(HU.C.accent.opacity(0.12)).frame(width: 36, height: 36)
                if let urlStr = binding.agentLogoUrl, let url = URL(string: urlStr) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().aspectRatio(contentMode: .fill)
                                .frame(width: 36, height: 36).clipShape(Circle())
                        default:
                            Text(String(binding.agentName.prefix(1)).uppercased())
                                .font(HU.title(.heavy)).foregroundStyle(HU.C.accent)
                        }
                    }
                } else {
                    Text(String(binding.agentName.prefix(1)).uppercased())
                        .font(HU.title(.heavy)).foregroundStyle(HU.C.accent)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(binding.agentName).font(HU.body(.medium)).foregroundStyle(HU.C.ink)
                Text(subtitle).font(HU.small()).foregroundStyle(HU.C.muted)
            }
            Spacer()
            if let unread = binding.unreadCount, unread > 0 {
                Text(unread > 99 ? "99+" : "\(unread)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(HU.C.bg)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(HU.C.accent))
            }
            Image(systemName: "chevron.right").font(.caption.weight(.medium)).foregroundStyle(HU.C.muted.opacity(0.7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

/// One-line persistent banner that explains a current blocker (no notification
/// permission, no network, etc.) and lets the user act on it. Shown at the top
/// of HomeView so users see it before they wonder "why isn't anything coming
/// through".
struct StatusBanner: View {
    let issue: StatusMonitor.Issue
    @EnvironmentObject var loc: Localizer

    private var content: (icon: String, zh: String, en: String, action: (() -> Void)?, actionLabel: (zh: String, en: String)?) {
        switch issue {
        case .notificationsDenied:
            return (
                "bell.slash.fill",
                "通知权限被关了。HeadsUp 现在收不到任何 agent 的推送。",
                "Notifications are off. HeadsUp can't deliver any pushes right now.",
                { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } },
                ("打开设置", "Open Settings")
            )
        case .notificationsNotDetermined:
            return (
                "bell.badge",
                "请允许 HeadsUp 发送通知。否则 agent 联系不到你。",
                "Allow HeadsUp to send notifications, or agents can't reach you.",
                { Task { await PushService.shared.requestAuthorization() } },
                ("允许", "Allow")
            )
        case .offline:
            return (
                "wifi.slash",
                "无网络。下面的列表可能不是最新的。",
                "Offline. The list below may be out of date.",
                nil, nil
            )
        case .cellularRestricted:
            return (
                "antenna.radiowaves.left.and.right.slash",
                "蜂窝数据被关了。Wi-Fi 不通时 HeadsUp 会失联。",
                "Cellular is off for HeadsUp. Without Wi-Fi the app goes silent.",
                { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } },
                ("打开设置", "Open Settings")
            )
        }
    }

    var body: some View {
        let c = content
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: c.icon)
                .font(.callout)
                .foregroundStyle(issue.isCritical ? HU.C.accent : HU.C.muted)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 8) {
                LText(c.zh, c.en)
                    .font(HU.small())
                    .foregroundStyle(HU.C.ink)
                    .lineSpacing(2)
                if let action = c.action, let label = c.actionLabel {
                    Button { action() } label: {
                        Text(T(label.zh, label.en))
                            .font(HU.small(.semibold))
                            .foregroundStyle(HU.C.bg)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(HU.C.ink))
                    }
                }
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(issue.isCritical ? HU.C.accent.opacity(0.08) : HU.C.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(issue.isCritical ? HU.C.accent.opacity(0.4) : HU.C.line, lineWidth: 1)
        )
    }
}

struct EmptyAgentsView: View {
    @Binding var showAddAgent: Bool
    @EnvironmentObject var deepLink: DeepLinkHandler
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var auth: AuthService
    @StateObject private var status = StatusMonitor.shared
    @State private var copiedInstruction = false

    private var instructionZH: String {
        "请读一下这个 URL(是网页,不是本地文件):https://headsup.md/skill.md — 它是 HeadsUp 的协议文档,讲清楚怎么给我发可以一键回复的推送。读完按文档注册账号,再发给我它生成的授权链接。"
    }
    private var instructionEN: String {
        "Read this URL (a public web page, not a local file): https://headsup.md/skill.md — it's the HeadsUp protocol, explaining how to send me push notifications I can reply to with one tap. Follow it: register yourself, then send me the authorization link it tells you to generate."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Spacer().frame(height: 24)

                HStack {
                    Eyebrow(text: "no agents yet")
                    Spacer()
                    LanguageToggle()
                }
                .padding(.horizontal, 32)

                if !status.activeIssues.isEmpty {
                    Spacer().frame(height: 16)
                    VStack(spacing: 8) {
                        ForEach(status.activeIssues, id: \.self) { issue in
                            StatusBanner(issue: issue)
                        }
                    }
                    .padding(.horizontal, 16)
                }

                Spacer().frame(height: 18)

                LText("等一个 heads up。", "Get a heads up.")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundStyle(HU.C.ink)
                    .padding(.horizontal, 32)

                Spacer().frame(height: 8)

                LText(
                    "AI agent 想给你发通知时,会发一个授权链接给你。点开它,就能在通知栏跟你说话。",
                    "When your AI wants to message you, it sends you a link. Tap it once to authorize, and it can find you right in the notification bar."
                )
                .font(HU.body())
                .foregroundStyle(HU.C.muted)
                .lineSpacing(4)
                .padding(.horizontal, 32)

                Spacer().frame(height: 36)

                VStack(alignment: .leading, spacing: 22) {
                    StepLine(num: "01",
                             zh: "把这一整段指令发给你的 AI:",
                             en: "Paste this whole instruction to your AI:")
                }
                .padding(.horizontal, 32)

                Spacer().frame(height: 14)

                VStack(alignment: .leading, spacing: 10) {
                    LText(instructionZH, instructionEN)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(HU.C.ink)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(HU.C.card)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(HU.C.line, lineWidth: 1)
                        )
                    Button {
                        UIPasteboard.general.string = loc.lang == .zh ? instructionZH : instructionEN
                        copiedInstruction = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedInstruction = false }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: copiedInstruction ? "checkmark" : "doc.on.doc")
                                .font(.caption.weight(.medium))
                            Text(copiedInstruction ? T("已复制", "Copied") : T("复制完整指令", "Copy full instruction"))
                                .font(HU.small(.semibold))
                        }
                        .foregroundStyle(HU.C.bg)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Capsule().fill(HU.C.ink))
                    }
                }
                .padding(.horizontal, 32)

                Spacer().frame(height: 28)

                VStack(alignment: .leading, spacing: 22) {
                    StepLine(num: "02",
                             zh: "它会注册账号,然后发一个授权链接给你",
                             en: "It registers itself, then sends you an authorization link")
                    StepLine(num: "03",
                             zh: "你点链接 → 在这里授权 → 它就能给你发推送了",
                             en: "Tap the link → authorize here → it can now send you pushes")
                }
                .padding(.horizontal, 32)

                Spacer().frame(height: 40)

                PrimaryButton(title: T("我已经有授权链接", "I have an authorization link"), icon: "arrow.right") {
                    showAddAgent = true
                }
                .padding(.horizontal, 32)

                Spacer().frame(height: 24)

                // Did you authorize before but see nothing? Most likely a session
                // mismatch after a server change. Make the recovery path obvious.
                VStack(alignment: .leading, spacing: 6) {
                    LText("已经授权过却看不到? 重新登录一次。",
                          "Authorized before but seeing nothing? Sign out and back in.")
                        .font(HU.small()).foregroundStyle(HU.C.muted)
                    Button { auth.signOut() } label: {
                        Text(T("登出", "Sign out"))
                            .font(HU.small(.semibold))
                            .foregroundStyle(HU.C.accent)
                    }
                }
                .padding(.horizontal, 32)

                Spacer().frame(height: 60)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct StepLine: View {
    let num: String
    let zh: String
    let en: String
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(num)
                .font(HU.eyebrow())
                .tracking(1.5)
                .foregroundStyle(HU.C.accent)
                .frame(width: 22, alignment: .leading)
            LText(zh, en).font(HU.body()).foregroundStyle(HU.C.ink.opacity(0.85))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
