import SwiftUI
import UIKit
import UserNotifications

struct HistoryItem: Codable, Identifiable {
    let message_id: String
    let agent_id: String
    let agent_name: String
    let agent_logo_url: String?
    let agent_accent_color: String?
    let title: String
    let body: String
    let category_id: String
    let sent_at: Date
    let button_id: String?
    let button_label: String?
    let responded_at: Date?

    var id: String { message_id }
}

struct AgentDetailView: View {
    @EnvironmentObject var auth: AuthService
    let binding: AgentBinding

    @State private var history: [HistoryItem] = []
    @State private var loading = false
    @State private var error: String?
    @State private var revoking = false
    @State private var deferring = false
    @State private var showDeferConfirm = false
    @State private var marking = false
    @State private var showMarkReadConfirm = false
    @State private var bindingState: AgentBinding? = nil
    @State private var showEditSheet = false
    @StateObject private var overrides = AgentOverrides.shared
    @Environment(\.dismiss) var dismiss

    /// Number of history rows that haven't been answered yet (excluding info_only).
    private var unreadCount: Int {
        history.filter { $0.button_id == nil && $0.category_id != "info_only" }.count
    }

    var body: some View {
        ZStack {
            HU.C.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Header
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Eyebrow(text: "agent")
                            Spacer()
                            Button(T("编辑", "Edit")) { showEditSheet = true }
                                .font(HU.small(.semibold))
                                .foregroundStyle(HU.C.muted)
                        }
                        Text(overrides.displayName(for: bindingState ?? binding))
                            .font(HU.display())
                            .foregroundStyle(HU.C.ink)
                        Text("授权于 \(binding.boundAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(HU.small())
                            .foregroundStyle(HU.C.muted)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 4)

                    // Stats row
                    HStack(spacing: 16) {
                        StatBox(value: "\(history.count)", label: "messages")
                        StatBox(value: "\(history.filter { $0.button_id != nil }.count)", label: "responded")
                    }
                    .padding(.horizontal, 24)

                    // History
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Eyebrow(text: "history")
                            Spacer()
                            if unreadCount > 0 {
                                Button {
                                    showMarkReadConfirm = true
                                } label: {
                                    HStack(spacing: 4) {
                                        if marking {
                                            ProgressView().scaleEffect(0.7).tint(HU.C.muted)
                                        } else {
                                            Image(systemName: "checkmark.circle")
                                                .font(.caption2)
                                        }
                                        Text(T("一键已读 (\(unreadCount))",
                                              "Mark \(unreadCount) read"))
                                            .font(HU.small(.semibold))
                                    }
                                    .foregroundStyle(HU.C.muted)
                                }
                                .disabled(marking || deferring)

                                Button {
                                    showDeferConfirm = true
                                } label: {
                                    HStack(spacing: 4) {
                                        if deferring {
                                            ProgressView().scaleEffect(0.7).tint(HU.C.muted)
                                        } else {
                                            Image(systemName: "clock.fill")
                                                .font(.caption2)
                                        }
                                        Text(T("稍后再说 (\(unreadCount))",
                                              "Defer \(unreadCount)"))
                                            .font(HU.small(.semibold))
                                    }
                                    .foregroundStyle(HU.C.accent)
                                }
                                .disabled(deferring || marking)
                            }
                        }
                        .padding(.horizontal, 24)

                        if loading && history.isEmpty {
                            ProgressView().frame(maxWidth: .infinity).tint(HU.C.muted)
                                .padding(.vertical, 40)
                        } else if history.isEmpty {
                            Text("还没收到这个 agent 的推送。")
                                .font(HU.body()).foregroundStyle(HU.C.muted)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 24)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(history.enumerated()), id: \.element.id) { idx, item in
                                    HistoryRow(item: item)
                                    if idx < history.count - 1 {
                                        Rectangle().fill(HU.C.line).frame(height: 1)
                                            .padding(.leading, 16)
                                    }
                                }
                            }
                            .card()
                            .padding(.horizontal, 16)
                        }
                    }

                    // Per-agent mute
                    MuteRow(binding: bindingState ?? binding) { newUntil in
                        // Patch the binding in-memory so the row reflects
                        // immediately, even before the next /bindings refresh.
                        var updated = bindingState ?? binding
                        let mirror = AgentBinding(
                            agentId: updated.agentId,
                            agentName: updated.agentName,
                            boundAt: updated.boundAt,
                            agentLogoUrl: updated.agentLogoUrl,
                            agentAccentColor: updated.agentAccentColor,
                            agentDescription: updated.agentDescription,
                            agentType: updated.agentType,
                            muteUntil: newUntil,
                            lastMessageAt: updated.lastMessageAt,
                            lastMessageTitle: updated.lastMessageTitle,
                            unreadCount: updated.unreadCount
                        )
                        bindingState = mirror
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    // Revoke
                    Button(role: .destructive) {
                        Task { await revoke() }
                    } label: {
                        HStack {
                            Spacer()
                            if revoking {
                                ProgressView().tint(HU.C.accent)
                            } else {
                                Text("撤销 agent 授权")
                                    .font(HU.body(.medium)).foregroundStyle(HU.C.accent)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 14)
                        .background(Capsule().strokeBorder(HU.C.accent, lineWidth: 1))
                    }
                    .disabled(revoking)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)

                    Text("撤销后，这个 agent 不能再给你发推送，需要重新授权。")
                        .font(HU.small())
                        .foregroundStyle(HU.C.muted)
                        .padding(.horizontal, 24)

                    if let error = error {
                        Text(error).font(HU.small()).foregroundStyle(HU.C.accent)
                            .padding(.horizontal, 24)
                    }

                    Spacer().frame(height: 40)
                }
                .padding(.vertical, 12)
            }
        }
        .navigationTitle("")
        .toolbarBackground(HU.C.bg, for: .navigationBar)
        .refreshable { await loadHistory() }
        .task { await loadHistory() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { await loadHistory() }
        }
        // Refresh whenever a new push arrives or the user taps a button.
        .onReceive(NotificationCenter.default.publisher(for: .headsupHistoryChanged)) { _ in
            Task { await loadHistory() }
        }
        .alert(T("清除 \(unreadCount) 条未读?", "Defer \(unreadCount) unread?"),
               isPresented: $showDeferConfirm) {
            Button(T("取消", "Cancel"), role: .cancel) {}
            Button(T("全部回复\"稍后再说\"", "Reply 'later' to all"), role: .destructive) {
                Task { await deferAllUnread() }
            }
        } message: {
            LText(
                "会向 \(binding.agentName) 发送 \(unreadCount) 条 \"稍后再说\" 回应。无法撤回。",
                "Sends \(unreadCount) 'later' replies to \(binding.agentName). Cannot be undone."
            )
        }
        .sheet(isPresented: $showEditSheet) {
            EditAgentSheet(binding: bindingState ?? binding)
        }
        .alert(T("标记 \(unreadCount) 条为已读?", "Mark \(unreadCount) as read?"),
               isPresented: $showMarkReadConfirm) {
            Button(T("取消", "Cancel"), role: .cancel) {}
            Button(T("标记已读", "Mark read")) {
                Task { await markAllRead() }
            }
        } message: {
            LText(
                "只在你这边清除未读 — 不会发任何回应给 \(binding.agentName)。",
                "Clears unread on your side only — no reply is sent to \(binding.agentName)."
            )
        }
    }

    private func deferAllUnread() async {
        guard let session = auth.session else { return }
        deferring = true
        defer { deferring = false }
        struct Resp: Decodable { let deferred: Int }
        struct Empty: Encodable {}
        do {
            let _: Resp = try await APIClient.shared.post(
                "/v1/app/bindings/\(binding.agentId)/defer-all-unread",
                body: Empty(),
                sessionToken: session.sessionToken
            )
            await loadHistory()
            NotificationCenter.default.post(name: .headsupHistoryChanged, object: nil)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func markAllRead() async {
        guard let session = auth.session else { return }
        marking = true
        defer { marking = false }
        struct Resp: Decodable { let marked: Int }
        struct Empty: Encodable {}
        do {
            let _: Resp = try await APIClient.shared.post(
                "/v1/app/bindings/\(binding.agentId)/mark-all-read",
                body: Empty(),
                sessionToken: session.sessionToken
            )
            // Drop those notifications from the lock screen too — we just told
            // the user "read", so they shouldn't keep seeing the banners.
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            await loadHistory()
            NotificationCenter.default.post(name: .headsupHistoryChanged, object: nil)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadHistory() async {
        guard let session = auth.session else { return }
        // Spinner only on the very first load — silent on event-driven refreshes
        // so the screen doesn't flash.
        if history.isEmpty { loading = true }
        defer { loading = false }
        do {
            let result: [HistoryItem] = try await APIClient.shared.get(
                "/v1/app/history?agent_id=\(binding.agentId)&limit=50",
                sessionToken: session.sessionToken
            )
            self.history = result
        } catch {
            if history.isEmpty { self.error = error.localizedDescription }
        }
    }

    private func revoke() async {
        guard let session = auth.session else { return }
        revoking = true
        defer { revoking = false }
        do {
            try await APIClient.shared.delete(
                "/v1/app/bindings/\(binding.agentId)",
                sessionToken: session.sessionToken
            )
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct HistoryRow: View {
    let item: HistoryItem
    var showAgentName: Bool = false
    @State private var actions: [(id: String, title: String)] = []
    @State private var sending: String? = nil      // button_id currently being sent
    @State private var localReply: String? = nil   // optimistic reply label
    @State private var copiedFeedback: Bool = false

    private var displayedReply: String? { localReply ?? item.button_label }

    private var isInfoOnly: Bool { item.category_id == "info_only" }

    /// Resolve the row's accent color from the server-provided hex (or a
    /// stable default keyed on the agent name, so detail-view rows that
    /// pre-date the field still get something sensible).
    private var accentColor: Color {
        if let hex = item.agent_accent_color, let c = Color(hex: hex) { return c }
        return AgentBranding.fallback(for: item.agent_name)
    }

    /// Render the body as Markdown if it parses; fall back to plain otherwise.
    /// `inlineOnlyAndDisableSubstitutions: true` means we don't try to make
    /// links tappable inside the row (handled at the row level).
    private var renderedBody: AttributedString {
        // Strip the trailing hint suffix (added by server) before parsing —
        // it's display chrome, not the agent's content.
        var raw = item.body
        for suffix in [
            "  （长按选择回复）", "  (long-press to reply)",
            "  （仅通知，无需回复）", "  (notification only — no reply needed)",
        ] {
            if raw.hasSuffix(suffix) {
                raw = String(raw.dropLast(suffix.count))
                break
            }
        }
        if let attr = try? AttributedString(markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return attr
        }
        return AttributedString(raw)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if showAgentName {
                AgentAvatar(name: item.agent_name,
                            logoUrl: item.agent_logo_url,
                            accent: accentColor,
                            size: 32)
                    .padding(.top, 2)
            }
            rowContent
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                UIPasteboard.general.string = plainBodyForCopy
            } label: {
                Label(T("复制内容", "Copy"), systemImage: "doc.on.doc")
            }
            Button {
                UIPasteboard.general.string = "\(item.title)\n\n\(plainBodyForCopy)"
            } label: {
                Label(T("复制标题+内容", "Copy with title"), systemImage: "doc.on.doc.fill")
            }
        }
        .task { await loadActions() }
    }

    @ViewBuilder
    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if showAgentName {
                    Text(item.agent_name).font(HU.eyebrow()).tracking(1.5).foregroundStyle(accentColor)
                }
                if isInfoOnly {
                    Text(T("仅通知", "INFO"))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(HU.C.muted)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().strokeBorder(HU.C.line, lineWidth: 1))
                }
                Spacer()
            }
            Text(item.title).font(HU.body(.semibold)).foregroundStyle(HU.C.ink)
            Text(renderedBody).font(HU.small()).foregroundStyle(HU.C.muted)
                .lineSpacing(2).lineLimit(3)
            HStack(spacing: 6) {
                Text(item.sent_at.formatted(date: .abbreviated, time: .shortened))
                    .font(HU.small()).foregroundStyle(HU.C.muted.opacity(0.7))
                Spacer()
                if let label = displayedReply {
                    Text("→ \(label)")
                        .font(HU.small(.semibold))
                        .foregroundStyle(HU.C.accent)
                }
                // Visible copy chip on EVERY row, regardless of reply state.
                // Long-press contextMenu still works for "with title" variant.
                Button {
                    UIPasteboard.general.string = plainBodyForCopy
                    copiedFeedback = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        copiedFeedback = false
                    }
                } label: {
                    Image(systemName: copiedFeedback ? "checkmark" : "doc.on.doc")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(copiedFeedback ? HU.C.accent : HU.C.muted)
                        .padding(6)
                        .background(Circle().fill(HU.C.line.opacity(0.5)))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
            // Inline reply buttons — only when no reply yet AND the category has buttons.
            if displayedReply == nil && item.category_id != "info_only" && !actions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(actions, id: \.id) { action in
                        Button {
                            Task { await reply(buttonId: action.id, buttonLabel: action.title) }
                        } label: {
                            Text(action.title)
                                .font(HU.small(.semibold))
                                .foregroundStyle(sending == action.id ? HU.C.muted : HU.C.ink)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(
                                    Capsule().strokeBorder(HU.C.ink, lineWidth: 1)
                                        .opacity(sending == nil ? 1 : 0.4)
                                )
                        }
                        .disabled(sending != nil)
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    /// Body without the server-appended hint ("（长按选择回复）" etc.) — what the
    /// user actually wants when they say "copy this".
    private var plainBodyForCopy: String {
        var s = item.body
        for suffix in [
            "  （长按选择回复）", "  (long-press to reply)",
            "  （仅通知，无需回复）", "  (notification only — no reply needed)",
        ] {
            if s.hasSuffix(suffix) { s = String(s.dropLast(suffix.count)); break }
        }
        return s
    }

    private func loadActions() async {
        guard displayedReply == nil, item.category_id != "info_only" else { return }
        // Look up the category's buttons from the in-app registry
        // (synced via silent push when the agent creates/changes a category).
        let cats = await withCheckedContinuation { cont in
            UNUserNotificationCenter.current().getNotificationCategories { cont.resume(returning: $0) }
        }
        if let cat = cats.first(where: { $0.identifier == item.category_id }) {
            self.actions = cat.actions.map { ($0.identifier, $0.title) }
        }
    }

    private func reply(buttonId: String, buttonLabel: String) async {
        guard let session = AuthService.shared.session else { return }
        sending = buttonId
        defer { sending = nil }
        // Optimistic — update UI before the network call completes
        localReply = buttonLabel
        struct Body: Encodable {
            let message_id: String
            let button_id: String
            let button_label: String
        }
        struct Resp: Decodable { let status: String? }
        do {
            let _: Resp = try await APIClient.shared.post(
                "/v1/app/actions/report",
                body: Body(message_id: item.message_id, button_id: buttonId, button_label: buttonLabel),
                sessionToken: session.sessionToken
            )
            NotificationCenter.default.post(name: .headsupHistoryChanged, object: nil)
        } catch {
            // Roll back the optimistic UI on failure
            localReply = nil
        }
    }
}

/// Lets the user override the agent's displayed name + accent color *on this
/// device only*. The agent's published name/color stay untouched on the
/// server (the agent might want them, other users see them).
struct EditAgentSheet: View {
    let binding: AgentBinding

    @Environment(\.dismiss) var dismiss
    @StateObject private var overrides = AgentOverrides.shared
    @State private var nickname: String = ""
    @State private var pickedHex: String? = nil

    private static let palette: [String] = [
        "#D97757", "#10A37F", "#5B8DEE", "#E8A33D",
        "#7C5CFC", "#C04E7E", "#3FA9A1", "#6B60A8",
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                HU.C.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Eyebrow(text: "rename")
                        TextField(binding.agentName, text: $nickname)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                            .background(HU.C.card)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(HU.C.line, lineWidth: 1)
                            )

                        Text(T("空着就用 agent 自己的名字: \(binding.agentName)。",
                               "Leave blank to use the agent's own name: \(binding.agentName)."))
                            .font(HU.small())
                            .foregroundStyle(HU.C.muted)

                        Spacer().frame(height: 8)

                        Eyebrow(text: "accent")
                        let cols = [GridItem(.adaptive(minimum: 44), spacing: 12)]
                        LazyVGrid(columns: cols, spacing: 12) {
                            ForEach(Self.palette, id: \.self) { hex in
                                Button {
                                    pickedHex = (pickedHex == hex) ? nil : hex
                                } label: {
                                    Circle()
                                        .fill(Color(hex: hex) ?? HU.C.muted)
                                        .frame(width: 36, height: 36)
                                        .overlay(
                                            Circle()
                                                .strokeBorder(
                                                    pickedHex == hex ? HU.C.ink : Color.clear,
                                                    lineWidth: 2
                                                )
                                                .padding(-3)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                            Button {
                                pickedHex = nil
                            } label: {
                                Circle()
                                    .strokeBorder(HU.C.line, lineWidth: 1)
                                    .frame(width: 36, height: 36)
                                    .overlay(
                                        Image(systemName: "arrow.uturn.backward")
                                            .font(.caption2)
                                            .foregroundStyle(HU.C.muted)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                        Text(T("不选就用 agent 默认配色。",
                               "No selection = the agent's own color."))
                            .font(HU.small())
                            .foregroundStyle(HU.C.muted)
                    }
                    .padding(24)
                }
            }
            .navigationTitle(T("编辑", "Edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(T("取消", "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(T("保存", "Save")) {
                        let n = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
                        overrides.setNickname(n.isEmpty ? nil : n, for: binding.agentId)
                        overrides.setAccentHex(pickedHex, for: binding.agentId)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            nickname = overrides.nickname(for: binding.agentId) ?? ""
            pickedHex = overrides.accentHex(for: binding.agentId)
        }
    }
}

private struct StatBox: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(HU.display()).foregroundStyle(HU.C.ink)
            Text(label).font(HU.eyebrow()).tracking(2).foregroundStyle(HU.C.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .card()
    }
}

/// Per-agent silence: 1h / 8h / 24h presets + Unmute. State is server-side
/// (AgentUserBinding.mute_until) so it survives reinstalls and matches what
/// the push pipeline actually checks.
private struct MuteRow: View {
    let binding: AgentBinding
    let onChange: (Date?) -> Void

    @State private var working = false
    @State private var showSheet = false

    private var isMuted: Bool { binding.isMuted }

    private var label: String {
        guard let until = binding.muteUntil, until > Date() else {
            return T("静音此 agent", "Mute this agent")
        }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return T(
            "静音中,\(fmt.localizedString(for: until, relativeTo: Date()))后恢复",
            "Muted, resumes \(fmt.localizedString(for: until, relativeTo: Date()))"
        )
    }

    var body: some View {
        Button {
            showSheet = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isMuted ? "bell.slash.fill" : "bell")
                    .font(.callout)
                    .foregroundStyle(isMuted ? HU.C.accent : HU.C.muted)
                Text(label)
                    .font(HU.body())
                    .foregroundStyle(HU.C.ink)
                Spacer()
                if working {
                    ProgressView().scaleEffect(0.7).tint(HU.C.muted)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(HU.C.muted.opacity(0.7))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
        .buttonStyle(.plain)
        .disabled(working)
        .confirmationDialog(
            T("静音 \(binding.agentName)", "Mute \(binding.agentName)"),
            isPresented: $showSheet,
            titleVisibility: .visible
        ) {
            Button(T("1 小时", "1 hour"))   { Task { await apply(minutes: 60) } }
            Button(T("8 小时", "8 hours"))  { Task { await apply(minutes: 480) } }
            Button(T("24 小时", "24 hours")) { Task { await apply(minutes: 1440) } }
            if isMuted {
                Button(T("取消静音", "Unmute"), role: .destructive) {
                    Task { await apply(minutes: 0) }
                }
            }
            Button(T("取消", "Cancel"), role: .cancel) {}
        }
    }

    private func apply(minutes: Int) async {
        guard let session = AuthService.shared.session else { return }
        working = true
        defer { working = false }
        struct Body: Encodable { let minutes: Int? }
        struct Resp: Decodable { let mute_until: Date? }
        do {
            let resp: Resp = try await APIClient.shared.post(
                "/v1/app/bindings/\(binding.agentId)/mute",
                body: Body(minutes: minutes > 0 ? minutes : nil),
                sessionToken: session.sessionToken
            )
            onChange(resp.mute_until)
        } catch {
            // Best-effort. Surface failures via the row label staying as-is.
        }
    }
}
