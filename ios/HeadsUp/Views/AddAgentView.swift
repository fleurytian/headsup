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
            ZStack {
                HU.C.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        Spacer().frame(height: 8)

                        VStack(alignment: .leading, spacing: 8) {
                            Eyebrow(text: "add agent")
                            Text("把授权链接\n粘贴这里。")
                                .font(.system(size: 26, weight: .heavy, design: .rounded))
                                .foregroundStyle(HU.C.ink)
                                .lineSpacing(4)
                        }
                        .padding(.horizontal, 24)

                        // Paste field
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("headsup://authorize?token=…", text: $pasteText, axis: .vertical)
                                .font(.system(.callout, design: .monospaced))
                                .padding(14)
                                .background(HU.C.card)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(HU.C.line, lineWidth: 1)
                                )
                                .lineLimit(1...3)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            HStack(spacing: 14) {
                                Button {
                                    if let s = UIPasteboard.general.string { pasteText = s }
                                } label: {
                                    Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                                        .font(HU.small())
                                        .foregroundStyle(HU.C.accent)
                                }
                                Spacer()
                            }
                            if let error = error {
                                Text(error).font(HU.small()).foregroundStyle(HU.C.accent)
                            }
                        }
                        .padding(.horizontal, 24)

                        PrimaryButton(title: "打开授权") { tryParseAndOpen() }
                            .padding(.horizontal, 24)
                            .disabled(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .opacity(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)

                        HairRule(label: "or")
                            .padding(.horizontal, 24)

                        // How-to
                        VStack(alignment: .leading, spacing: 18) {
                            Eyebrow(text: "how to get one")

                            StepRow(num: "01", text: "让你的 AI Agent（Hermes、Claude Code、OpenClaw、Codex 等）先读这个 URL 学协议：")

                            // Copy chip
                            HStack(spacing: 8) {
                                Text(skillURL)
                                    .font(.system(size: 12, design: .monospaced))
                                    .lineLimit(1).truncationMode(.middle)
                                    .foregroundStyle(HU.C.ink)
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(HU.C.card)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(HU.C.line, lineWidth: 1)
                                    )
                                Button {
                                    UIPasteboard.general.string = skillURL
                                    copiedSkillURL = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedSkillURL = false }
                                } label: {
                                    Text(copiedSkillURL ? "已复制" : "复制")
                                        .font(HU.small(.semibold))
                                        .foregroundStyle(HU.C.bg)
                                        .padding(.horizontal, 14).padding(.vertical, 8)
                                        .background(Capsule().fill(HU.C.ink))
                                }
                            }
                            .padding(.leading, 38)

                            StepRow(num: "02", text: "Agent 自己注册账号，把 headsup:// 链接发给你")
                            StepRow(num: "03", text: "点链接 → Safari → 「Open in HeadsUp」会跳回这里授权")
                        }
                        .padding(.horizontal, 24)

                        Spacer().frame(height: 32)
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .font(HU.body()).foregroundStyle(HU.C.muted)
                }
            }
            .toolbarBackground(HU.C.bg, for: .navigationBar)
        }
    }

    private func tryParseAndOpen() {
        let trimmed = pasteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { error = "链接格式不对"; return }
        guard url.scheme == "headsup", url.host == "authorize" else {
            error = "这不是 HeadsUp 授权链接（应以 headsup://authorize 开头）"; return
        }
        deepLink.handle(url: url)
        dismiss()
    }
}

private struct StepRow: View {
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
