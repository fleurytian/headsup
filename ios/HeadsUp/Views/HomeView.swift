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
    @State private var todayStats: TodayStats? = nil
    @State private var clipboardLink: String? = nil
    @State private var hasEverAuthorized = UserDefaults.standard.bool(forKey: "headsup.hasEverAuthorizedAgent")
    /// Coalesce burst refresh events. `.task`, foreground, deep-link change,
    /// and `.headsupHistoryChanged` all fire reload — without debouncing,
    /// a single user reply could trigger 3 simultaneous /bindings calls.
    @State private var bindingsRefreshTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ZStack {
                HU.C.bg.ignoresSafeArea()

                if bindings.isEmpty && !loading {
                    EmptyAgentsView(showAddAgent: $showAddAgent,
                                    hasEverAuthorized: hasEverAuthorized)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            // Setup checklist — only renders when something
                            // is incomplete. Once everything is green it
                            // hides entirely so power users aren't nagged.
                            SetupChecklist(bindingsCount: bindings.count)
                                .padding(.horizontal, 16)
                            ForEach(status.activeIssues, id: \.self) { issue in
                                StatusBanner(issue: issue).padding(.horizontal, 16)
                            }
                            if let link = clipboardLink {
                                ClipboardDetectCard(link: link, dismiss: { clipboardLink = nil })
                                    .padding(.horizontal, 16)
                            }
                            HStack(alignment: .firstTextBaseline) {
                                Eyebrow(text: "agents · \(bindings.count)")
                                Spacer()
                                if let s = todayStats {
                                    Text(todaySummary(s))
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .foregroundStyle(HU.C.muted)
                                }
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

                            Button {
                                showAddAgent = true
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "plus")
                                        .font(.caption.weight(.semibold))
                                    LText("添加 agent", "Add agent")
                                        .font(HU.small(.semibold))
                                }
                                .frame(maxWidth: .infinity)
                                .foregroundStyle(HU.C.muted)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 4)
                            .padding(.bottom, 88)
                        }
                        .padding(.vertical, 16)
                    }
                }

                if !bindings.isEmpty || loading {
                    VStack {
                        Spacer()
                        HomeBottomDock(showAddAgent: $showAddAgent)
                            .padding(.horizontal, 28)
                            .padding(.bottom, 14)
                    }
                }
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("HeadsUp")
                        .font(HU.title(.bold))
                        .foregroundStyle(HU.C.ink)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.headline)
                            .foregroundStyle(HU.C.ink)
                    }
                }
            }
            .toolbarBackground(HU.C.bg, for: .navigationBar)
            // Pull-to-refresh forces an immediate reload.
            .refreshable { await loadBindings() }
            .task { await loadBindings() }
            // Other reload triggers go through the debouncer to coalesce
            // bursts: a tap on a reply button can fire history-changed +
            // foreground + deep-link in quick succession.
            .onChange(of: deepLink.pendingAuthorize?.id) { _ in
                scheduleBindingsRefresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                scheduleBindingsRefresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: .headsupHistoryChanged)) { _ in
                scheduleBindingsRefresh()
            }
            .sheet(isPresented: $showAddAgent) {
                AddAgentView()
            }
        }
    }

    /// Debounced reload — collapse bursts to a single API hit.
    private func scheduleBindingsRefresh() {
        bindingsRefreshTask?.cancel()
        bindingsRefreshTask = Task {
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
            guard !Task.isCancelled else { return }
            await loadBindings()
            bindingsRefreshTask = nil
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
            if !result.isEmpty {
                hasEverAuthorized = true
                UserDefaults.standard.set(true, forKey: "headsup.hasEverAuthorizedAgent")
                clipboardLink = nil
            }
        } catch {
            self.error = error.localizedDescription
        }
        await loadTodayStats()
        checkClipboard()
    }

    private func loadTodayStats() async {
        guard let session = auth.session else { return }
        do {
            let s: TodayStats = try await APIClient.shared.get(
                "/v1/app/me/stats", sessionToken: session.sessionToken
            )
            self.todayStats = s
        } catch {}
    }

    /// If the user just copied an authorize link in Safari, surface it the
    /// moment they land on home. UIPasteboard reads cost a "pasted from X"
    /// system toast — we only check on app foreground / view appear, not
    /// continuously.
    private func checkClipboard() {
        guard !hasEverAuthorized, bindings.isEmpty else {
            clipboardLink = nil
            return
        }
        let pb = UIPasteboard.general
        guard pb.hasStrings || pb.hasURLs else { clipboardLink = nil; return }
        let candidate: String? = {
            if let url = pb.url, url.scheme == "headsup" || url.host?.hasSuffix("headsup.md") == true {
                return url.absoluteString
            }
            if let s = pb.string,
               s.lowercased().hasPrefix("headsup://authorize")
                || s.lowercased().hasPrefix("https://headsup.md/authorize") {
                return s
            }
            return nil
        }()
        clipboardLink = candidate
    }

    private func todaySummary(_ s: TodayStats) -> String {
        let lang = loc.lang
        let parts: [String]
        if lang == .zh {
            parts = [
                "今日 \(s.received_today)",
                "已回 \(s.replied_today)",
                s.unread_total > 0 ? "待回 \(s.unread_total)" : "全清"
            ]
        } else {
            parts = [
                "\(s.received_today) today",
                "\(s.replied_today) replied",
                s.unread_total > 0 ? "\(s.unread_total) pending" : "all clear"
            ]
        }
        return parts.joined(separator: " · ")
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

private struct HomeBottomDock: View {
    @Binding var showAddAgent: Bool
    // T() returns a plain String, snapshotted at view-construction time,
    // so we need to observe Localizer here for the body to re-render
    // when the user toggles ZH/EN. Without this, "历史 / 我的" stay
    // stuck in whichever language the dock was first built with.
    @EnvironmentObject var loc: Localizer

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            NavigationLink {
                HistoryView()
            } label: {
                dockItem(icon: "clock", label: T("历史", "History"))
            }
            .buttonStyle(.plain)

            Button {
                showAddAgent = true
            } label: {
                ZStack {
                    Circle()
                        .fill(HU.C.ink)
                        .frame(width: 62, height: 62)
                        .shadow(color: HU.C.ink.opacity(0.16), radius: 18, y: 8)
                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(HU.C.bg)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(T("添加 agent", "Add agent"))

            NavigationLink {
                ProfileView()
            } label: {
                dockItem(icon: "person.crop.circle", label: T("我的", "Profile"))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .clipShape(Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(HU.C.line.opacity(0.75), lineWidth: 1))
    }

    private func dockItem(icon: String, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
            Text(label)
                .font(.system(size: 10, weight: .medium))
        }
        .frame(width: 58)
        .foregroundStyle(HU.C.ink)
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

    @StateObject private var overrides = AgentOverrides.shared

    private var accent: Color { overrides.displayAccent(for: binding) }
    private var displayName: String { overrides.displayName(for: binding) }

    var body: some View {
        HStack(spacing: 14) {
            AgentAvatar(name: displayName,
                        logoUrl: binding.agentLogoUrl,
                        accent: accent,
                        size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName).font(HU.body(.medium)).foregroundStyle(HU.C.ink)
                if let title = binding.lastMessageTitle, !title.isEmpty {
                    Text(title)
                        .font(HU.small())
                        .foregroundStyle(HU.C.ink.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(subtitle).font(HU.small()).foregroundStyle(HU.C.muted)
            }
            Spacer()
            if binding.isMuted {
                Image(systemName: "bell.slash.fill")
                    .font(.caption2)
                    .foregroundStyle(HU.C.muted)
            }
            if let unread = binding.unreadCount, unread > 0 {
                Text(unread > 99 ? "99+" : "\(unread)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(HU.C.bg)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(accent))
            }
            Image(systemName: "chevron.right").font(.caption.weight(.medium)).foregroundStyle(HU.C.muted.opacity(0.7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

/// First-time-success checklist. Shows the four things that must all be
/// true for the user to actually receive an agent's pings: signed in,
/// notifications allowed, APNs device token registered, and at least one
/// agent bound. Each row turns green as it's completed; once the whole
/// list is green the view returns EmptyView() so it doesn't permanently
/// occupy the home screen.
///
/// Implementation note: signed-in is implicitly true because HomeView only
/// renders when AuthService has a session, but we display a row for it
/// anyway so the user sees their own session as part of the picture.
struct SetupChecklist: View {
    let bindingsCount: Int

    @EnvironmentObject var auth: AuthService
    @EnvironmentObject var push: PushService
    @StateObject private var status = StatusMonitor.shared

    private var signedIn: Bool { auth.session != nil }
    private var notifyOn: Bool { status.notificationStatus == .authorized || status.notificationStatus == .provisional }
    private var deviceTokenSet: Bool { push.deviceTokenString?.isEmpty == false }
    private var hasAnyAgent: Bool { bindingsCount > 0 }

    private var allGood: Bool {
        signedIn && notifyOn && deviceTokenSet && hasAnyAgent
    }

    var body: some View {
        if allGood {
            // Once everything is green, get out of the user's way entirely.
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow(text: "setup")
                row(done: signedIn,
                    zh: "已登录", en: "Signed in",
                    zhFix: nil, enFix: nil)
                row(done: notifyOn,
                    zh: "通知权限已开",
                    en: "Notifications allowed",
                    zhFix: "去设置打开",
                    enFix: "Open Settings",
                    fix: notifyOn ? nil : openNotifSettings)
                row(done: deviceTokenSet,
                    zh: "设备已注册到 APNs",
                    en: "Device registered with APNs",
                    zhFix: deviceTokenSet ? nil : "通常几秒后自动完成。如果一直没好,重启 App 一次。",
                    enFix: deviceTokenSet ? nil : "Usually completes within seconds. Restart the app if it doesn't.",
                    fix: nil)
                row(done: hasAnyAgent,
                    zh: "至少授权一个 agent",
                    en: "Authorized at least one agent",
                    zhFix: hasAnyAgent ? nil : "把 headsup.md/skill.md 给你的 AI 让它发授权链接",
                    enFix: hasAnyAgent ? nil : "Hand headsup.md/skill.md to your AI to get an authorization link",
                    fix: nil)
            }
            .padding(14)
            .background(HU.C.card)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(HU.C.line, lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func row(done: Bool,
                     zh: String, en: String,
                     zhFix: String? = nil, enFix: String? = nil,
                     fix: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.callout)
                    .foregroundStyle(done ? HU.C.ink : HU.C.muted.opacity(0.5))
                LText(zh, en)
                    .font(HU.body())
                    .foregroundStyle(done ? HU.C.ink.opacity(0.55) : HU.C.ink)
                    .strikethrough(done, color: HU.C.muted)
                Spacer()
                if !done, let fix {
                    Button(action: fix) {
                        LText(zhFix ?? "", enFix ?? "")
                            .font(HU.small(.semibold))
                            .foregroundStyle(HU.C.accent)
                    }
                }
            }
            if !done, fix == nil, let zhFix, let enFix {
                LText(zhFix, enFix)
                    .font(HU.small())
                    .foregroundStyle(HU.C.muted)
                    .padding(.leading, 26)
            }
        }
    }

    private func openNotifSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
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

/// Plain-data shape returned by /v1/app/me/stats.
struct TodayStats: Codable {
    let received_today: Int
    let replied_today: Int
    let unread_total: Int
}

/// One-line card: "We saw a `headsup://authorize?...` in your clipboard. Open it?"
struct ClipboardDetectCard: View {
    let link: String
    let dismiss: () -> Void
    @EnvironmentObject var deepLink: DeepLinkHandler

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "link").font(.callout).foregroundStyle(HU.C.accent)
            VStack(alignment: .leading, spacing: 2) {
                LText("剪贴板有授权链接", "Authorize link in clipboard")
                    .font(HU.small(.semibold)).foregroundStyle(HU.C.ink)
                Text(link.prefix(60) + (link.count > 60 ? "…" : ""))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(HU.C.muted)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                if let url = URL(string: link) {
                    deepLink.handle(url: url)
                }
                dismiss()
            } label: {
                Text(T("打开", "Open"))
                    .font(HU.small(.semibold)).foregroundStyle(HU.C.bg)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(HU.C.ink))
            }
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.caption2).foregroundStyle(HU.C.muted)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(HU.C.accent.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(HU.C.accent.opacity(0.4), lineWidth: 1))
    }
}

struct EmptyAgentsView: View {
    @Binding var showAddAgent: Bool
    var hasEverAuthorized: Bool = false
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

                if hasEverAuthorized {
                    LText("一个都没了。", "All clear.")
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundStyle(HU.C.ink)
                        .padding(.horizontal, 32)
                    Spacer().frame(height: 8)
                    LText(
                        "你撤销了所有 agent。再绑一个,或者收到新链接时直接粘到下面。",
                        "You revoked every agent. Add one again, or paste a new authorization link below."
                    )
                    .font(HU.body())
                    .foregroundStyle(HU.C.muted)
                    .lineSpacing(4)
                    .padding(.horizontal, 32)
                } else {
                    LText("等一个 Headsup。", "Gets a Headsup.")
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
                }

                Spacer().frame(height: 36)

                if !hasEverAuthorized {
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
                }

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
