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
                    VStack(spacing: 22) {
                        // Header
                        VStack(spacing: 8) {
                            ZStack {
                                Circle().fill(HU.pastelGradient.opacity(0.5))
                                    .frame(width: 78, height: 78)
                                Image(systemName: "link.badge.plus")
                                    .font(.system(size: 32, weight: .medium))
                                    .foregroundStyle(.white)
                            }
                            Text("ADD  AGENT")
                                .font(HU.rounded(20, weight: .heavy)).tracking(4)
                                .foregroundStyle(HU.C.ink)
                            Text("\(HU.diamond)  PASTE  AUTHORIZATION  LINK  \(HU.diamond)")
                                .font(HU.mono(10, weight: .medium)).tracking(2)
                                .foregroundStyle(HU.C.lavender)
                        }
                        .padding(.top, 12)

                        // Paste box
                        VStack(alignment: .leading, spacing: 10) {
                            RetroLabel(text: "AUTH  LINK")
                            VStack(spacing: 10) {
                                TextField("headsup://authorize?token=…", text: $pasteText, axis: .vertical)
                                    .font(.system(.callout, design: .monospaced))
                                    .padding(12)
                                    .background(HU.C.bg)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(HU.C.dotted.opacity(0.3),
                                                style: StrokeStyle(lineWidth: 1, dash: [3,3]))
                                    )
                                    .lineLimit(2)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                                Button {
                                    if let s = UIPasteboard.general.string { pasteText = s }
                                } label: {
                                    Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                                        .font(HU.rounded(12)).tracking(0.5)
                                        .foregroundStyle(HU.C.lavender)
                                }
                            }
                            if let error = error {
                                Text(error).font(HU.mono(11)).foregroundStyle(HU.C.pink)
                            }
                        }
                        .padding(16).vaporCard().padding(.horizontal, 20)

                        VaporButton(title: "打开授权", icon: "sparkles", primary: true) {
                            tryParseAndOpen()
                        }
                        .disabled(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .padding(.horizontal, 24)

                        Text("\(HU.bullet)  OR  \(HU.bullet)")
                            .font(HU.mono(11)).tracking(3).foregroundStyle(HU.C.muted)

                        // How-to guide
                        VStack(alignment: .leading, spacing: 14) {
                            RetroLabel(text: "HOW  TO  GET  A  LINK")

                            HelpStep(num: "1", text: "让你的 AI Agent（Hermes、Claude Code、OpenClaw、Codex 等）先读这个 URL 学协议：")

                            HStack(spacing: 8) {
                                Text(skillURL)
                                    .font(HU.mono(11))
                                    .lineLimit(1).truncationMode(.middle)
                                    .foregroundStyle(HU.C.ink)
                                    .padding(.horizontal, 10).padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(HU.C.bg)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(HU.C.dotted.opacity(0.3),
                                                style: StrokeStyle(lineWidth: 1, dash: [3,3]))
                                    )
                                Button {
                                    UIPasteboard.general.string = skillURL
                                    copiedSkillURL = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedSkillURL = false }
                                } label: {
                                    Label(copiedSkillURL ? "已复制" : "复制",
                                          systemImage: copiedSkillURL ? "checkmark" : "doc.on.doc")
                                        .font(HU.mono(11, weight: .medium)).tracking(0.5)
                                }
                                .buttonStyle(.bordered).tint(HU.C.lavender)
                                .controlSize(.small)
                            }
                            .padding(.leading, 30)

                            HelpStep(num: "2", text: "Agent 自己注册账号，把 headsup:// 授权链接发给你")
                            HelpStep(num: "3", text: "点链接 → Safari → 「Open in HeadsUp」会跳回这里授权")
                        }
                        .padding(16).vaporCard().padding(.horizontal, 20)
                        .padding(.bottom, 24)
                    }
                    .padding(.top, 8)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .font(HU.rounded(14)).foregroundStyle(HU.C.muted)
                }
            }
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

private struct HelpStep: View {
    let num: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(num)
                .font(HU.mono(11, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(HU.C.lavender.opacity(0.15)))
                .foregroundStyle(HU.C.lavender)
            Text(text).font(HU.rounded(13)).foregroundStyle(HU.C.ink.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
