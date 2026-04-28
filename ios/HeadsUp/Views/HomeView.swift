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
                        VStack(spacing: 14) {
                            HStack {
                                RetroLabel(text: "AUTHORIZED  AGENTS")
                                Spacer()
                                Text("\(bindings.count)").font(HU.mono(11, weight: .semibold))
                                    .foregroundStyle(HU.C.muted)
                            }
                            .padding(.horizontal, 4)

                            ForEach(bindings) { agent in
                                NavigationLink(destination: AgentDetailView(binding: agent)) {
                                    AgentRow(binding: agent)
                                }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .trailing) {
                                    Button("撤销", role: .destructive) {
                                        Task { await revoke(agent) }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                }
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showAddAgent = true } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundStyle(HU.C.lavender)
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text("HEADSUP")
                        .font(HU.rounded(14, weight: .heavy))
                        .tracking(4)
                        .foregroundStyle(HU.C.ink)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "person.crop.circle")
                            .font(.title2)
                            .foregroundStyle(HU.C.muted)
                    }
                }
            }
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
                Circle().fill(HU.pastelGradient).frame(width: 44, height: 44)
                Text(String(binding.agentName.prefix(1)).uppercased())
                    .font(HU.rounded(18, weight: .heavy))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(binding.agentName).font(HU.rounded(16, weight: .medium)).foregroundStyle(HU.C.ink)
                Text("\(HU.bullet) bound \(binding.boundAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(HU.mono(10)).tracking(0.3).foregroundStyle(HU.C.muted)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(HU.C.muted.opacity(0.5))
        }
        .padding(14)
        .vaporCard()
    }
}

struct EmptyAgentsView: View {
    @Binding var showAddAgent: Bool
    @EnvironmentObject var deepLink: DeepLinkHandler

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer().frame(height: 40)

                ZStack {
                    Circle().fill(HU.pastelGradient.opacity(0.18)).frame(width: 140, height: 140)
                    VStack(spacing: 4) {
                        Text("🌙").font(.system(size: 48))
                        Text("zzz").font(HU.mono(11)).tracking(2).foregroundStyle(HU.C.muted)
                    }
                }

                VStack(spacing: 8) {
                    Text("没有 Agent")
                        .font(HU.rounded(20, weight: .bold)).tracking(2)
                        .foregroundStyle(HU.C.ink)
                    Text("\(HU.diamond)  WAITING FOR INVITATION  \(HU.diamond)")
                        .font(HU.mono(10, weight: .medium)).tracking(2)
                        .foregroundStyle(HU.C.muted)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("HOW IT WORKS")
                        .font(HU.mono(10, weight: .semibold)).tracking(2)
                        .foregroundStyle(HU.C.lavender)
                    BulletLine(text: "你的 AI 助手会读 headsup.md/skill.md 学协议")
                    BulletLine(text: "它会发一个 headsup:// 授权链接给你")
                    BulletLine(text: "点开 → 一次授权 → 它就能在通知栏找你")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .vaporCard()
                .padding(.horizontal, 20)

                VaporButton(title: "添加 Agent", icon: "plus") {
                    showAddAgent = true
                }
                .padding(.horizontal, 32)
                .padding(.top, 4)

                Text("\(HU.bullet) pull to refresh \(HU.bullet)")
                    .font(HU.mono(10)).tracking(2).foregroundStyle(HU.C.muted.opacity(0.6))
            }
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct BulletLine: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(HU.star).font(HU.mono(11)).foregroundStyle(HU.C.pink)
            Text(text).font(HU.rounded(13)).foregroundStyle(HU.C.ink.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
