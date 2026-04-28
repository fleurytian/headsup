import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject var auth: AuthService
    @EnvironmentObject var deepLink: DeepLinkHandler
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
                                        Button("撤销", role: .destructive) {
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
                                Text("拉下来刷新").font(HU.small())
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

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(HU.C.accent.opacity(0.12)).frame(width: 36, height: 36)
                Text(String(binding.agentName.prefix(1)).uppercased())
                    .font(HU.title(.heavy))
                    .foregroundStyle(HU.C.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(binding.agentName).font(HU.body(.medium)).foregroundStyle(HU.C.ink)
                Text(binding.boundAt.formatted(date: .abbreviated, time: .shortened))
                    .font(HU.small()).foregroundStyle(HU.C.muted)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.medium)).foregroundStyle(HU.C.muted.opacity(0.7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

struct EmptyAgentsView: View {
    @Binding var showAddAgent: Bool
    @EnvironmentObject var deepLink: DeepLinkHandler

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Spacer().frame(height: 32)

                Eyebrow(text: "no agents yet")
                    .padding(.horizontal, 32)

                Spacer().frame(height: 18)

                Text("等一个邀请。")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundStyle(HU.C.ink)
                    .padding(.horizontal, 32)

                Spacer().frame(height: 8)

                Text("AI agent 想给你发通知时，会发一个授权链接给你。点开链接，就能让它在通知栏跟你说话。")
                    .font(HU.body())
                    .foregroundStyle(HU.C.muted)
                    .lineSpacing(4)
                    .padding(.horizontal, 32)

                Spacer().frame(height: 36)

                // Three steps, magazine layout
                VStack(alignment: .leading, spacing: 22) {
                    StepLine(num: "01", text: "让你的 AI 助手读 headsup.md/skill.md 学协议")
                    StepLine(num: "02", text: "它会发一个 headsup:// 链接给你")
                    StepLine(num: "03", text: "你点链接 → 在 App 里授权 → 完成")
                }
                .padding(.horizontal, 32)

                Spacer().frame(height: 40)

                PrimaryButton(title: "添加 Agent", icon: "plus") {
                    showAddAgent = true
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
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(num)
                .font(HU.eyebrow())
                .tracking(1.5)
                .foregroundStyle(HU.C.accent)
                .frame(width: 22, alignment: .leading)
            Text(text).font(HU.body()).foregroundStyle(HU.C.ink.opacity(0.85))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
