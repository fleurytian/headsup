import SwiftUI
import UIKit

struct AddAgentView: View {
    @EnvironmentObject var deepLink: DeepLinkHandler
    @Environment(\.dismiss) var dismiss
    @State private var pasteText: String = ""
    @State private var error: String?
    @State private var copiedSkillURL = false

    private let skillURL = "https://headsup.md/skill.md"

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "link.badge.plus").font(.system(size: 48)).foregroundStyle(.tint)
                    Text("添加新 Agent").font(.title3.bold())
                    Text("把 Agent 给你的授权链接粘贴这里")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 24)

                // Paste box
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("headsup://authorize?token=…", text: $pasteText, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(2)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(.callout, design: .monospaced))
                    }
                    Button {
                        if let s = UIPasteboard.general.string {
                            pasteText = s
                        }
                    } label: {
                        Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                    }
                    .font(.callout)

                    if let error = error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 24)

                Button {
                    tryParseAndOpen()
                } label: {
                    Text("打开授权").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(.horizontal, 24)

                Divider().padding(.vertical, 4)

                // How-to guide
                VStack(alignment: .leading, spacing: 12) {
                    Text("怎么获得授权链接？").font(.subheadline.weight(.medium))

                    HelpStep(num: "1", text: "让你的 AI Agent（Hermes、Claude Code、OpenClaw、Codex 等）先读这个 URL 学协议：")

                    HStack(spacing: 8) {
                        Text(skillURL)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.gray.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Button {
                            UIPasteboard.general.string = skillURL
                            copiedSkillURL = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedSkillURL = false }
                        } label: {
                            Label(copiedSkillURL ? "已复制" : "复制", systemImage: copiedSkillURL ? "checkmark" : "doc.on.doc")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.leading, 34)

                    HelpStep(num: "2", text: "Agent 自己注册账号，并把 headsup:// 授权链接发给你")
                    HelpStep(num: "3", text: "点链接 → Safari → 「Open in HeadsUp」会跳回这里授权；或粘贴到上面")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)

                Spacer()
            }
            .navigationTitle("Add Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func tryParseAndOpen() {
        let trimmed = pasteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            error = "链接格式不对"
            return
        }
        guard url.scheme == "headsup", url.host == "authorize" else {
            error = "这不是 HeadsUp 授权链接（应该以 headsup://authorize 开头）"
            return
        }
        deepLink.handle(url: url)
        dismiss()
    }
}

private struct HelpStep: View {
    let num: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(num)
                .font(.caption.weight(.bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.tint.opacity(0.15)))
                .foregroundStyle(.tint)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
