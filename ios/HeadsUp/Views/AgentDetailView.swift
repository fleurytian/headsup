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
    // Observed so language toggles re-render — T() returns a snapshot
    // String, not a reactive value. Without this, ZH labels in the
    // detail page (Edit, mute / unread chips, alerts) stay stuck.
    @EnvironmentObject var loc: Localizer
    let binding: AgentBinding

    @State private var history: [HistoryItem] = []
    @State private var agentBadges: [BadgeItem] = []
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

    /// Pre-resolved button definitions per category, looked up *once* at
    /// view load and refresh, instead of letting every HistoryRow do its
    /// own UNUserNotificationCenter.getNotificationCategories() call. With
    /// 50-row history that was up to 50 system queries per refresh; now
    /// it's 1.
    @State private var categoryButtons: [String: [HistoryRow.Action]] = [:]

    /// Coalesce burst refresh events. Reply / mark-as-read / new-push /
    /// foreground can fire in the same tick — debouncing avoids hitting
    /// the API 4x for what's effectively one user-perceptible event.
    @State private var historyRefreshTask: Task<Void, Never>?

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

                    if !agentBadges.isEmpty {
                        AgentBadgeStrip(badges: agentBadges)
                            .padding(.horizontal, 16)
                    }

                    // History
                    VStack(alignment: .leading, spacing: 12) {
                        Eyebrow(text: "history")
                            .padding(.horizontal, 24)

                        // Two real buttons (capsule outlines), only when there
                        // are unanswered messages. Equal width so they read as
                        // a paired choice — pick one of two ways to clear.
                        if unreadCount > 0 {
                            HStack(spacing: 10) {
                                BulkActionButton(
                                    icon: marking ? nil : "checkmark.circle",
                                    busy: marking,
                                    label: T("一键已读 (\(unreadCount))",
                                            "Mark \(unreadCount) read"),
                                    tint: HU.C.muted,
                                    action: { showMarkReadConfirm = true }
                                )
                                .disabled(marking || deferring)

                                BulkActionButton(
                                    icon: deferring ? nil : "clock.fill",
                                    busy: deferring,
                                    label: T("稍后再说 (\(unreadCount))",
                                            "Defer \(unreadCount)"),
                                    tint: HU.C.accent,
                                    action: { showDeferConfirm = true }
                                )
                                .disabled(deferring || marking)
                            }
                            .padding(.horizontal, 16)
                        }

                        if loading && history.isEmpty {
                            ProgressView().frame(maxWidth: .infinity).tint(HU.C.muted)
                                .padding(.vertical, 40)
                        } else if history.isEmpty {
                            Text("还没收到这个 agent 的推送。")
                                .font(HU.body()).foregroundStyle(HU.C.muted)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 24)
                        } else {
                            // LazyVStack — only renders visible rows; cheap
                            // even at 200 history items. Plain VStack would
                            // build everything (Markdown, contextMenu, button
                            // task per row) up front on appear.
                            LazyVStack(spacing: 0) {
                                ForEach(Array(history.enumerated()), id: \.element.id) { idx, item in
                                    HistoryRow(
                                        item: item,
                                        actions: categoryButtons[item.category_id] ?? []
                                    )
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
                        let updated = bindingState ?? binding
                        bindingState = AgentBinding(
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
        // Pull-to-refresh forces a full reload (categories + badges + history).
        .refreshable { await loadAll(force: true) }
        // First appearance: load everything in parallel.
        .task { await loadAll(force: true) }
        // Foreground: refresh history + categories (badges accumulate slowly,
        // skip them — they're refetched on full pull-to-refresh).
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            scheduleHistoryRefresh()
        }
        // Reply / mark-as-read / bulk-defer / new push: history-only refresh,
        // debounced so a burst of events coalesces into one fetch.
        .onReceive(NotificationCenter.default.publisher(for: .headsupHistoryChanged)) { _ in
            scheduleHistoryRefresh()
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

    /// Full reload — every data source. Used on initial appear and
    /// pull-to-refresh. Runs the three fetches in parallel.
    private func loadAll(force: Bool) async {
        async let h: Void = loadHistory()
        async let b: Void = loadAgentBadges()
        async let c: Void = loadCategoryButtons()
        _ = await (h, b, c)
    }

    /// Debounced history refresh. Bursts (e.g., webhook + foreground +
    /// reply ack landing in the same tick) collapse to one API call.
    private func scheduleHistoryRefresh() {
        historyRefreshTask?.cancel()
        historyRefreshTask = Task {
            // 50ms is enough to coalesce a typical burst without feeling laggy.
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            await loadHistory()
            historyRefreshTask = nil
        }
    }

    /// Hoist `getNotificationCategories` to the parent — one call per
    /// reload instead of per-row. Stored in `categoryButtons` and passed
    /// down to HistoryRow.
    private func loadCategoryButtons() async {
        let cats = await withCheckedContinuation { cont in
            UNUserNotificationCenter.current().getNotificationCategories { cont.resume(returning: $0) }
        }
        var result: [String: [HistoryRow.Action]] = [:]
        for c in cats {
            result[c.identifier] = c.actions.map { HistoryRow.Action(id: $0.identifier, title: $0.title) }
        }
        self.categoryButtons = result
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

    private func loadAgentBadges() async {
        guard let session = auth.session else { return }
        do {
            let response: BadgesResponse = try await APIClient.shared.get(
                "/v1/app/bindings/\(binding.agentId)/badges",
                sessionToken: session.sessionToken
            )
            self.agentBadges = response.badges
        } catch {
            self.agentBadges = []
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
    /// Resolved button definition, hoisted out of UNUserNotificationCenter
    /// at the parent level (AgentDetailView / HistoryView). HistoryRow
    /// no longer queries iOS itself — it just reads what the parent gave it.
    struct Action: Hashable {
        let id: String
        let title: String
    }

    let item: HistoryItem
    var showAgentName: Bool = false
    /// Already-resolved buttons for this row's category. Empty array means
    /// "no buttons / info_only". Plumbed in instead of fetched per-row.
    var actions: [Action] = []

    @State private var sending: String? = nil      // button_id currently being sent
    @State private var localReply: String? = nil   // optimistic reply label
    @State private var copiedFeedback: Bool = false

    /// Cached AttributedString — Markdown parse is expensive enough that
    /// re-running it on every body redraw (button-state changes, copy
    /// feedback flicker, parent refresh) was visible in instruments. We
    /// compute it once when the row first appears and again only if
    /// `item.body` actually changes.
    @State private var renderedBodyCache: AttributedString = AttributedString()
    @State private var plainBodyCache: String = ""

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
    /// Pure function so .task can call it once per row body. Strips the
    /// server-appended hint suffix (long-press hint, info-only marker)
    /// before parsing — it's display chrome, not the agent's content.
    private static func renderBody(_ raw: String) -> (plain: String, rendered: AttributedString) {
        var s = raw
        for suffix in [
            "  （长按选择回复）", "  (long-press to reply)",
            "  （仅通知，无需回复）", "  (notification only — no reply needed)",
        ] {
            if s.hasSuffix(suffix) {
                s = String(s.dropLast(suffix.count))
                break
            }
        }
        let rendered: AttributedString
        if let attr = try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            rendered = attr
        } else {
            rendered = AttributedString(s)
        }
        return (s, rendered)
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
                UIPasteboard.general.string = plainBodyCache
            } label: {
                Label(T("复制内容", "Copy"), systemImage: "doc.on.doc")
            }
            Button {
                UIPasteboard.general.string = "\(item.title)\n\n\(plainBodyCache)"
            } label: {
                Label(T("复制标题+内容", "Copy with title"), systemImage: "doc.on.doc.fill")
            }
        }
        // Compute markdown + plain body once per row body. .task(id:)
        // re-fires only when the body string itself changes (e.g. push
        // edited mid-render — never happens today, but defensive).
        .task(id: item.body) {
            let (plain, rendered) = Self.renderBody(item.body)
            self.plainBodyCache = plain
            self.renderedBodyCache = rendered
        }
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
            Text(renderedBodyCache).font(HU.small()).foregroundStyle(HU.C.muted)
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
                    UIPasteboard.general.string = plainBodyCache
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

/// Capsule-outline action button used in pairs in AgentDetailView for
/// "mark all read" / "defer all". Equal width via `frame(maxWidth: .infinity)`
/// so the two buttons read as a paired choice; tint controls the foreground
/// color so the destructive-ish defer (sends real replies to the agent) can
/// be visually distinct from the silent mark-as-read.
private struct BulkActionButton: View {
    var icon: String?
    var busy: Bool = false
    let label: String
    var tint: Color = HU.C.ink
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy {
                    ProgressView().scaleEffect(0.7).tint(tint)
                } else if let icon {
                    Image(systemName: icon).font(.caption.weight(.medium))
                }
                Text(label).font(HU.small(.semibold))
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Capsule().strokeBorder(tint.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct AgentBadgeStrip: View {
    let badges: [BadgeItem]
    @EnvironmentObject var loc: Localizer
    @State private var selected: BadgeItem?

    private var visible: [BadgeItem] { Array(badges.prefix(8)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow(text: "badges")
                Spacer()
                Text("\(badges.count)")
                    .font(HU.small(.semibold))
                    .foregroundStyle(HU.C.muted)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(visible) { badge in
                        Button {
                            selected = badge
                        } label: {
                            VStack(spacing: 6) {
                                BadgeSymbolMark(badge: badge, size: 46, iconSize: 20)
                                Text(loc.lang == .zh ? badge.name_zh : badge.name_en)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(HU.C.muted)
                                    .lineLimit(1)
                                    .frame(width: 64)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(14)
        .card()
        .sheet(item: $selected) { badge in
            BadgeDetailSheet(badge: badge)
                .presentationDetents([.medium])
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
        } message: {
            // Be explicit about what the agent sees — Codex flagged that
            // users can otherwise assume mute = "queue silently and deliver
            // later" while agents see the 429 rejection and treat their
            // task as failed. Aligning both sides removes that mismatch.
            LText(
                "静音期间,这个 agent 发的 push 会被立即拒收(返回 429),不是排队稍后送达。它会知道你暂时不接收。其他已授权的 agent 不受影响。",
                "While muted, this agent's pushes are rejected immediately (429) — not queued for later. The agent knows you're not accepting messages right now. Other authorized agents are unaffected."
            )
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
