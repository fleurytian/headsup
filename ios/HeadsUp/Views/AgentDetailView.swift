import SwiftUI
import UIKit

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
    @Environment(\.dismiss) var dismiss

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
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showAgentName {
                Text(item.agent_name).font(HU.eyebrow()).tracking(1.5).foregroundStyle(HU.C.accent)
            }
            Text(item.title).font(HU.body(.semibold)).foregroundStyle(HU.C.ink)
            Text(item.body).font(HU.small()).foregroundStyle(HU.C.muted)
                .lineSpacing(2).lineLimit(3)
            HStack(spacing: 6) {
                Text(item.sent_at.formatted(date: .abbreviated, time: .shortened))
                    .font(HU.small()).foregroundStyle(HU.C.muted.opacity(0.7))
                Spacer()
                if let label = item.button_label {
                    Text("→ \(label)")
                        .font(HU.small(.semibold))
                        .foregroundStyle(HU.C.accent)
                } else {
                    Text("未响应")
                        .font(HU.small())
                        .foregroundStyle(HU.C.muted.opacity(0.7))
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
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
