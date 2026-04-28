import SwiftUI

struct HomeView: View {
    @EnvironmentObject var auth: AuthService
    @EnvironmentObject var deepLink: DeepLinkHandler
    @State private var bindings: [AgentBinding] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if bindings.isEmpty && !loading {
                    EmptyAgentsView()
                } else {
                    List {
                        Section("Authorized Agents") {
                            ForEach(bindings) { agent in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(agent.agentName).font(.body)
                                        Text("Bound \(agent.boundAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .swipeActions(edge: .trailing) {
                                    Button("Revoke", role: .destructive) {
                                        Task { await revoke(agent) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("HeadsUp")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                }
            }
            .refreshable {
                await loadBindings()
            }
            .task {
                await loadBindings()
            }
            .onChange(of: deepLink.pendingAuthorize?.id) { _ in
                Task { await loadBindings() }
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

struct EmptyAgentsView: View {
    @EnvironmentObject var deepLink: DeepLinkHandler
    @State private var pasteFieldText: String = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer().frame(height: 60)
                Image(systemName: "tray")
                    .font(.system(size: 56))
                    .foregroundStyle(.tertiary)
                VStack(spacing: 8) {
                    Text("还没有 Agent").font(.title3.weight(.semibold))
                    Text("当你的 AI 助手要在手机上联系你时，\n它会发一个授权链接给你。\n点开链接就能授权它给你发推送。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Divider().padding(.vertical, 8)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Or paste an authorization link")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    HStack {
                        TextField("headsup://authorize?...", text: $pasteFieldText)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit { tryParseLink() }
                        Button("Open") { tryParseLink() }
                            .disabled(pasteFieldText.isEmpty)
                    }
                    Button {
                        if let s = UIPasteboard.general.string {
                            pasteFieldText = s
                            tryParseLink()
                        }
                    } label: {
                        Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                            .font(.caption)
                    }
                }
                .padding(.horizontal, 24)

                Text("（拉下来刷新列表）").font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 40)
        }
    }

    private func tryParseLink() {
        let trimmed = pasteFieldText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme == "headsup",
              url.host == "authorize" else { return }
        deepLink.handle(url: url)
        pasteFieldText = ""
    }
}
