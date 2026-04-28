import SwiftUI

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
    @State private var revoked = false
    @Environment(\.dismiss) var dismiss

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(binding.agentName).font(.title3.bold())
                    Text("授权于 \(binding.boundAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("最近推送 (\(history.count))") {
                if loading && history.isEmpty {
                    ProgressView().frame(maxWidth: .infinity)
                } else if history.isEmpty {
                    Text("还没收到这个 agent 的推送").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(history) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.title).font(.body.weight(.medium))
                            Text(item.body).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                            HStack(spacing: 8) {
                                Text(item.sent_at.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2).foregroundStyle(.tertiary)
                                if let label = item.button_label {
                                    Spacer()
                                    Label(label, systemImage: "checkmark.circle.fill")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.tint)
                                } else {
                                    Spacer()
                                    Text("未响应").font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    Task { await revoke() }
                } label: {
                    if revoking {
                        ProgressView()
                    } else {
                        Label("撤销 agent 授权", systemImage: "xmark.circle.fill")
                    }
                }
                .disabled(revoking)
            } footer: {
                Text("撤销后，这个 agent 不能再给你发推送，需要重新授权。")
            }

            if let error = error {
                Section {
                    Text(error).foregroundStyle(.red).font(.caption)
                }
            }
        }
        .navigationTitle(binding.agentName)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await loadHistory() }
        .task { await loadHistory() }
    }

    private func loadHistory() async {
        guard let session = auth.session else { return }
        loading = true
        defer { loading = false }
        do {
            let result: [HistoryItem] = try await APIClient.shared.get(
                "/v1/app/history?agent_id=\(binding.agentId)&limit=50",
                sessionToken: session.sessionToken
            )
            self.history = result
        } catch {
            self.error = error.localizedDescription
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
            revoked = true
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
