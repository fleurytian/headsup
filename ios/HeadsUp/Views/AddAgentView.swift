import SwiftUI
import UIKit

struct AddAgentView: View {
    @EnvironmentObject var deepLink: DeepLinkHandler
    @EnvironmentObject var loc: Localizer
    @Environment(\.dismiss) var dismiss
    @State private var pasteText: String = ""
    @State private var error: String?
    @State private var copiedInstruction = false

    private var instructionZH: String {
        "请读一下这个 URL(是网页,不是本地文件):https://headsup.md/skill.md — 它是 HeadsUp 的协议文档,讲清楚怎么给我发可以一键回复的推送。读完按文档注册账号,再发给我它生成的授权链接。"
    }
    private var instructionEN: String {
        "Read this URL (a public web page, not a local file): https://headsup.md/skill.md — it's the HeadsUp protocol, explaining how to send me push notifications I can reply to with one tap. Follow it: register yourself, then send me the authorization link it tells you to generate."
    }

    var body: some View {
        NavigationStack {
            ZStack {
                HU.C.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        Spacer().frame(height: 8)

                        VStack(alignment: .leading, spacing: 8) {
                            Eyebrow(text: "add agent")
                            LText("把授权链接\n粘贴这里。", "Paste the\nauthorization link.")
                                .font(.system(size: 26, weight: .heavy, design: .rounded))
                                .foregroundStyle(HU.C.ink)
                                .lineSpacing(4)
                        }
                        .padding(.horizontal, 24)

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
                            Button {
                                if let s = UIPasteboard.general.string { pasteText = s }
                            } label: {
                                Label(T("从剪贴板粘贴", "Paste from clipboard"), systemImage: "doc.on.clipboard")
                                    .font(HU.small())
                                    .foregroundStyle(HU.C.accent)
                            }
                            if let error = error {
                                Text(error).font(HU.small()).foregroundStyle(HU.C.accent)
                            }
                        }
                        .padding(.horizontal, 24)

                        PrimaryButton(title: T("打开授权", "Open authorization")) { tryParseAndOpen() }
                            .padding(.horizontal, 24)
                            .disabled(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .opacity(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)

                        HairRule(label: "or")
                            .padding(.horizontal, 24)

                        VStack(alignment: .leading, spacing: 18) {
                            Eyebrow(text: "how to get one")

                            StepRow(num: "01",
                                    zh: "把这一整段指令发给你的 AI(Claude Code、Codex、Hermes、OpenClaw 等):",
                                    en: "Paste this whole instruction to your AI (Claude Code, Codex, Hermes, OpenClaw, etc.):")

                            VStack(alignment: .leading, spacing: 10) {
                                LText(instructionZH, instructionEN)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(HU.C.ink)
                                    .padding(14)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(HU.C.card)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(HU.C.line, lineWidth: 1)
                                    )
                                Button {
                                    UIPasteboard.general.string = loc.lang == .zh ? instructionZH : instructionEN
                                    copiedInstruction = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedInstruction = false }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: copiedInstruction ? "checkmark" : "doc.on.doc")
                                            .font(.caption.weight(.medium))
                                        Text(copiedInstruction ? T("已复制完整指令", "Copied full instruction") : T("复制完整指令", "Copy full instruction"))
                                            .font(HU.small(.semibold))
                                    }
                                    .foregroundStyle(HU.C.bg)
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(Capsule().fill(HU.C.ink))
                                }
                            }
                            .padding(.leading, 38)

                            StepRow(num: "02",
                                    zh: "Agent 注册账号后,会发一个授权链接给你(headsup:// 或 https://headsup.md/authorize 都行)",
                                    en: "Once registered, the agent sends you an authorization link (either a headsup:// deep link or an https://headsup.md/authorize URL)")
                            StepRow(num: "03",
                                    zh: "Safari 里点开 → 跳回这里授权,或直接把链接粘到上面的输入框",
                                    en: "Tap it in Safari to come back here, or paste the link into the field above")
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
                    Button(T("取消", "Cancel")) { dismiss() }
                        .font(HU.body()).foregroundStyle(HU.C.muted)
                }
            }
            .toolbarBackground(HU.C.bg, for: .navigationBar)
        }
    }

    private func tryParseAndOpen() {
        let trimmed = pasteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            error = T("链接格式不对", "Invalid link"); return
        }
        // Accept both:
        //   headsup://authorize?token=...&agent_id=...
        //   https://headsup.md/authorize?token=...&agent_id=...
        let isDeepLink = url.scheme == "headsup" && url.host == "authorize"
        let isWebLink  = (url.scheme == "https" || url.scheme == "http")
                         && url.host?.hasSuffix("headsup.md") == true
                         && url.path == "/authorize"
        guard isDeepLink || isWebLink else {
            error = T("这不是 HeadsUp 授权链接", "Not a HeadsUp authorization link"); return
        }
        let target: URL
        if isWebLink {
            // Rebuild as headsup://authorize?... so DeepLinkHandler accepts it.
            var c = URLComponents()
            c.scheme = "headsup"
            c.host   = "authorize"
            c.queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            guard let rebuilt = c.url else {
                error = T("链接格式不对", "Invalid link"); return
            }
            target = rebuilt
        } else {
            target = url
        }
        deepLink.handle(url: target)
        dismiss()
    }
}

private struct StepRow: View {
    let num: String
    let zh: String
    let en: String
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(num)
                .font(HU.eyebrow())
                .tracking(1.5)
                .foregroundStyle(HU.C.accent)
                .frame(width: 22, alignment: .leading)
            LText(zh, en).font(HU.body()).foregroundStyle(HU.C.ink.opacity(0.85))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
