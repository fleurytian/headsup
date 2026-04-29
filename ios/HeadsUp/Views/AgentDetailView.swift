import SwiftUI
import UIKit
import UserNotifications

struct HistoryItem: Codable, Identifiable {
    let message_id: String
    let agent_id: String
    let agent_name: String
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
                        Eyebrow(text: "agent")
                        Text(binding.agentName)
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
                                    showDeferConfirm = true
                                } label: {
                                    HStack(spacing: 4) {
                                        if deferring {
                                            ProgressView().scaleEffect(0.7).tint(HU.C.muted)
                                        } else {
                                            Image(systemName: "clock.fill")
                                                .font(.caption2)
                                        }
                                        Text(T("一键清除未读 (\(unreadCount))",
                                              "Defer \(unreadCount) unread"))
                                            .font(HU.small(.semibold))
                                    }
                                    .foregroundStyle(HU.C.accent)
                                }
                                .disabled(deferring)
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

    private var displayedReply: String? { localReply ?? item.button_label }

    private var isInfoOnly: Bool { item.category_id == "info_only" }

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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if showAgentName {
                    Text(item.agent_name).font(HU.eyebrow()).tracking(1.5).foregroundStyle(HU.C.accent)
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
                } else if isInfoOnly {
                    // info_only doesn't expect a reply — don't say "未响应"
                    EmptyView()
                }
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
