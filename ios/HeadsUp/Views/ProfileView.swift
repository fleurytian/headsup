import SwiftUI

/// Bottom-dock "我的 / Profile" — flat dashboard rather than a list of buttons.
///
/// Surfaces every "me"-scoped signal directly:
///   - Hero stats: agents, total received, total replied, response rate
///   - Latest 6 earned badges (full-color) + "All badges →" link to the
///     full grid (BadgesView)
///   - 24-hour activity histogram
///   - "Share invite" button — generates a brand-y card image of your
///     stats and pops the iOS share sheet so friends can install
///
/// Settings stays for system config (notifications / DND / account /
/// diagnose / privacy). Stuff that belongs to "you as a HeadsUp user"
/// lives here.
struct ProfileView: View {
    @EnvironmentObject var auth: AuthService
    @EnvironmentObject var loc: Localizer

    @State private var data: MyDataPayload?
    @State private var badges: BadgesResponse?
    @State private var bindingsCount: Int = 0
    /// Setting this presents the share sheet — using `.sheet(item:)` with
    /// an Identifiable payload instead of the prior `isPresented + opt`
    /// pair, which had a SwiftUI race where the sheet body sometimes
    /// rendered before the payload was set, blanking the sheet (Codex
    /// caught this).
    @State private var sharePayload: ShareImagePayload?
    @State private var selectedBadge: BadgeItem?

    var body: some View {
        ZStack {
            HU.C.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Spacer().frame(height: 4)

                    // ── Hero stats — 4 cells in a 2×2 grid ─────────────────
                    statsGrid
                        .padding(.horizontal, 16)

                    // ── Latest badges strip ────────────────────────────────
                    badgesStrip
                        .padding(.horizontal, 16)

                    // ── 24h activity histogram ─────────────────────────────
                    if let d = data, d.hour_histogram.contains(where: { $0 > 0 }) {
                        histogramCard(d)
                            .padding(.horizontal, 16)
                    }

                    // ── Share invite ───────────────────────────────────────
                    Button {
                        sharePayload = makeSharePayload()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.callout.weight(.medium))
                            LText("生成邀请图分享给朋友",
                                  "Share an invite card with a friend")
                                .font(HU.small(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(HU.C.bg)
                        .background(Capsule().fill(HU.C.ink))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)

                    Spacer().frame(height: 60)
                }
                .padding(.vertical, 12)
            }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(T("我的", "Profile"))
                    .font(HU.title(.bold))
                    .foregroundStyle(HU.C.ink)
            }
        }
        .toolbarBackground(HU.C.bg, for: .navigationBar)
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $sharePayload) { p in
            ShareInviteSheet(payload: p)
        }
        .sheet(item: $selectedBadge) { b in
            BadgeDetailSheet(badge: b)
        }
    }

    // ── Stats grid ───────────────────────────────────────────────────────────

    private var statsGrid: some View {
        let received = data?.total_received ?? 0
        let replied  = data?.total_replied ?? 0
        let pct: String = data?.response_rate.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                statCard(value: "\(bindingsCount)",
                         label: T("agent", "agents"),
                         emphasis: true)
                statCard(value: "\(received)",
                         label: T("总收到", "received"))
            }
            HStack(spacing: 10) {
                statCard(value: "\(replied)",
                         label: T("已回复", "replied"))
                statCard(value: pct,
                         label: T("响应率", "response rate"))
            }
        }
    }

    private func statCard(value: String, label: String, emphasis: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundStyle(emphasis ? HU.C.accent : HU.C.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(HU.eyebrow())
                .tracking(2)
                .foregroundStyle(HU.C.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .card()
    }

    // ── Badges strip ─────────────────────────────────────────────────────────

    private var badgesStrip: some View {
        let earned = (badges?.badges ?? []).filter { $0.earned }
            .sorted { ($0.earned_at ?? "") > ($1.earned_at ?? "") }
        let preview = Array(earned.prefix(6))
        let total   = badges?.total_visible ?? 0
        let earnedCount = badges?.earned_count ?? earned.count

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow(text: "badges")
                Spacer()
                Text("\(earnedCount)/\(total)")
                    .font(HU.eyebrow())
                    .tracking(1.5)
                    .foregroundStyle(HU.C.muted)
            }
            .padding(.horizontal, 8)

            if preview.isEmpty {
                Text(T("还没解锁徽章。给 agent 多用用就有了。",
                       "No badges yet. Use HeadsUp a bit and they'll unlock."))
                    .font(HU.small())
                    .foregroundStyle(HU.C.muted)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(preview) { b in
                            Button {
                                selectedBadge = b
                            } label: {
                                VStack(spacing: 6) {
                                    BadgeSymbolMark(badge: b, size: 56, iconSize: 24)
                                    Text(loc.lang == .zh ? b.name_zh : b.name_en)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(HU.C.ink)
                                        .lineLimit(1)
                                        .frame(maxWidth: 70)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .card()
            }

            NavigationLink(destination: BadgesView()) {
                HStack(spacing: 6) {
                    LText("查看全部徽章", "All badges")
                        .font(HU.small(.semibold))
                    Image(systemName: "arrow.right")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(HU.C.accent)
                .padding(.horizontal, 8)
                .padding(.top, 2)
            }
        }
    }

    // ── 24-hour activity histogram (re-uses MyDataView's chart logic) ────────

    private func histogramCard(_ d: MyDataPayload) -> some View {
        let max = max(d.hour_histogram.max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "last 24h")
                .padding(.horizontal, 8)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<24, id: \.self) { h in
                    let v = d.hour_histogram[h]
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(v > 0 ? HU.C.accent : HU.C.line)
                        .frame(maxWidth: .infinity)
                        .frame(height: max == 0 ? 4 : CGFloat(v) / CGFloat(max) * 60 + 4)
                }
            }
            .padding(14)
            .card()
        }
    }

    // ── Loading + share ──────────────────────────────────────────────────────

    private func load() async {
        guard let session = auth.session else { return }
        async let dPayload: MyDataPayload? = try? APIClient.shared.get(
            "/v1/app/me/data", sessionToken: session.sessionToken
        )
        async let bPayload: BadgesResponse? = try? APIClient.shared.get(
            "/v1/app/me/badges", sessionToken: session.sessionToken
        )
        async let bindings: [AgentBinding]? = try? APIClient.shared.get(
            "/v1/app/bindings", sessionToken: session.sessionToken
        )
        data = await dPayload
        badges = await bPayload
        bindingsCount = (await bindings)?.count ?? 0
    }

    private func makeSharePayload() -> ShareImagePayload {
        ShareImagePayload(
            received: data?.total_received ?? 0,
            replied:  data?.total_replied ?? 0,
            responseRatePct: data?.response_rate.map { Int(($0 * 100).rounded()) },
            agents: bindingsCount,
            badgesEarned: badges?.earned_count ?? 0,
            lang: loc.lang
        )
    }
}

// ── Share invite ────────────────────────────────────────────────────────────

struct ShareImagePayload: Identifiable {
    let id = UUID()
    let received: Int
    let replied: Int
    let responseRatePct: Int?
    let agents: Int
    let badgesEarned: Int
    let lang: AppLanguage
}

/// Renders the invite card via SwiftUI's ImageRenderer (iOS 16+) and pops
/// the standard iOS share sheet. The card itself is small, brand-aligned,
/// and contains no PII — just numbers and a URL.
struct ShareInviteSheet: View {
    let payload: ShareImagePayload
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var loc: Localizer
    @State private var renderedImage: UIImage?
    @State private var imageURL: URL?

    var body: some View {
        NavigationStack {
            ZStack {
                HU.C.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 20) {
                        Spacer().frame(height: 8)
                        InviteCard(payload: payload)
                            .frame(width: 320, height: 480)
                            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                            .shadow(color: .black.opacity(0.08), radius: 12, y: 4)

                        if let img = renderedImage, let url = imageURL {
                            ShareLink(
                                item: url,
                                preview: SharePreview(
                                    payload.lang == .zh ? "HeadsUp 邀请" : "Join me on HeadsUp",
                                    image: Image(uiImage: img)
                                )
                            ) {
                                HStack(spacing: 8) {
                                    Image(systemName: "square.and.arrow.up")
                                    Text(payload.lang == .zh ? "分享" : "Share")
                                }
                                .font(HU.body(.semibold))
                                .foregroundStyle(HU.C.bg)
                                .padding(.horizontal, 28).padding(.vertical, 12)
                                .background(Capsule().fill(HU.C.ink))
                            }
                            .buttonStyle(.plain)
                        } else {
                            ProgressView().tint(HU.C.muted)
                        }

                        Text(payload.lang == .zh
                             ? "图里只有数字和 headsup.md 链接,不会暴露你的账号或消息内容。"
                             : "The card has only numbers and a headsup.md link — no account info or message content.")
                            .font(HU.small())
                            .foregroundStyle(HU.C.muted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .padding(.vertical, 12)
                }
            }
            .navigationTitle(payload.lang == .zh ? "邀请图" : "Invite card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(payload.lang == .zh ? "关闭" : "Close") { dismiss() }
                }
            }
        }
        .task { await render() }
    }

    @MainActor
    private func render() async {
        let view = InviteCard(payload: payload)
            .frame(width: 1080, height: 1620)  // 2:3, prints clean on Stories / Twitter
            .background(Color(red: 0.973, green: 0.953, blue: 0.929))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        if let ui = renderer.uiImage {
            self.renderedImage = ui
            self.imageURL = writeShareImage(ui)
        }
    }

    private func writeShareImage(_ image: UIImage) -> URL? {
        guard let data = image.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("headsup-invite-\(UUID().uuidString).png")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

/// The actual visual layout of the invite. Brand cream background, big
/// stat block, tiny CTA at the bottom. Designed at 1080×1620 (2:3) and
/// rendered down for the on-screen preview at the same aspect ratio.
private struct InviteCard: View {
    let payload: ShareImagePayload

    private var lang: AppLanguage { payload.lang }
    private var heading: String {
        lang == .zh
            ? "我用 HeadsUp 让\nAI 给我提醒。"
            : "My AI texts me on the lock screen."
    }
    private var body1: String {
        lang == .zh
            ? "Yes / No / Wait — 不用打开任何 App。"
            : "Yes / No / Wait — without opening a thing."
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let scale = w / 320  // values below are tuned for 320pt; scale up cleanly
            VStack(alignment: .leading, spacing: 16 * scale) {
                Text("HEADSUP · MD")
                    .font(.system(size: 11 * scale, weight: .semibold, design: .monospaced))
                    .tracking(2 * scale)
                    .foregroundStyle(Color(red: 0.514, green: 0.498, blue: 0.475))

                Spacer().frame(height: 8 * scale)

                Text(heading)
                    .font(.system(size: 26 * scale, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color(red: 0.102, green: 0.094, blue: 0.094))
                    .lineSpacing(4 * scale)
                    .fixedSize(horizontal: false, vertical: true)

                Text(body1)
                    .font(.system(size: 14 * scale, weight: .regular))
                    .italic()
                    .foregroundStyle(Color(red: 0.514, green: 0.498, blue: 0.475))

                Spacer().frame(height: 16 * scale)

                // Stat strip
                HStack(spacing: 12 * scale) {
                    statColumn(big: "\(payload.received)",
                               small: lang == .zh ? "收到" : "received",
                               scale: scale)
                    statColumn(big: payload.responseRatePct.map { "\($0)%" } ?? "—",
                               small: lang == .zh ? "回复率" : "reply rate",
                               scale: scale)
                    statColumn(big: "\(payload.agents)",
                               small: lang == .zh ? "agent" : "agents",
                               scale: scale)
                }

                Spacer()

                // Bottom CTA
                VStack(alignment: .leading, spacing: 6 * scale) {
                    Text(lang == .zh
                         ? "你也可以让 AI 给你提醒:"
                         : "Want yours to too?")
                        .font(.system(size: 13 * scale))
                        .foregroundStyle(Color(red: 0.514, green: 0.498, blue: 0.475))
                    Text("headsup.md")
                        .font(.system(size: 22 * scale, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color(red: 0.420, green: 0.376, blue: 0.659))
                }
            }
            .padding(28 * scale)
            .frame(width: w, height: geo.size.height, alignment: .topLeading)
            .background(Color(red: 0.973, green: 0.953, blue: 0.929))
        }
    }

    private func statColumn(big: String, small: String, scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2 * scale) {
            Text(big)
                .font(.system(size: 22 * scale, weight: .heavy, design: .rounded))
                .foregroundStyle(Color(red: 0.102, green: 0.094, blue: 0.094))
            Text(small)
                .font(.system(size: 9 * scale, weight: .semibold, design: .monospaced))
                .tracking(1 * scale)
                .foregroundStyle(Color(red: 0.514, green: 0.498, blue: 0.475))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
