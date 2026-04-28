import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var auth: AuthService
    @State private var items: [HistoryItem] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        ZStack {
            HU.C.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Spacer().frame(height: 4)

                    VStack(alignment: .leading, spacing: 6) {
                        Eyebrow(text: "all activity")
                        Text("历史消息")
                            .font(HU.display())
                            .foregroundStyle(HU.C.ink)
                        Text("所有 agent 给你发过的推送 + 你的回应")
                            .font(HU.small())
                            .foregroundStyle(HU.C.muted)
                    }
                    .padding(.horizontal, 24)

                    // Stats
                    HStack(spacing: 16) {
                        statBox(value: "\(items.count)", label: "messages")
                        statBox(value: "\(items.filter { $0.button_id != nil }.count)", label: "responded")
                        statBox(value: "\(uniqueAgentCount)", label: "agents")
                    }
                    .padding(.horizontal, 24)

                    if loading && items.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).tint(HU.C.muted)
                            .padding(.vertical, 40)
                    } else if items.isEmpty {
                        VStack(spacing: 8) {
                            Eyebrow(text: "empty")
                            Text("还没有历史。\nAgent 给你发推送会出现在这里。")
                                .font(HU.body()).foregroundStyle(HU.C.muted)
                                .multilineTextAlignment(.center).lineSpacing(4)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 50)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                                HistoryRow(item: item, showAgentName: true)
                                if idx < items.count - 1 {
                                    Rectangle().fill(HU.C.line).frame(height: 1)
                                        .padding(.leading, 16)
                                }
                            }
                        }
                        .card()
                        .padding(.horizontal, 16)
                    }

                    Spacer().frame(height: 24)
                }
                .padding(.vertical, 12)
            }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("History").font(HU.title(.bold)).foregroundStyle(HU.C.ink)
            }
        }
        .toolbarBackground(HU.C.bg, for: .navigationBar)
        .refreshable { await load() }
        .task { await load() }
    }

    private var uniqueAgentCount: Int {
        Set(items.map { $0.agent_id }).count
    }

    private func statBox(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(HU.display()).foregroundStyle(HU.C.ink)
            Text(label).font(HU.eyebrow()).tracking(2).foregroundStyle(HU.C.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .card()
    }

    private func load() async {
        guard let session = auth.session else { return }
        loading = true
        defer { loading = false }
        do {
            let result: [HistoryItem] = try await APIClient.shared.get(
                "/v1/app/history?limit=100",
                sessionToken: session.sessionToken
            )
            self.items = result
        } catch {
            self.error = error.localizedDescription
        }
    }
}
