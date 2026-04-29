import SwiftUI

struct BadgeItem: Codable, Identifiable {
    let id: String
    let scope: String
    let name_zh: String
    let name_en: String
    let description_zh: String
    let description_en: String
    let icon: String
    let secret: Bool
    let early: Bool
    let earned_at: String?

    var earned: Bool { earned_at != nil }
}

struct BadgesResponse: Codable {
    let badges: [BadgeItem]
    let earned_count: Int
    let total_visible: Int
}

/// Settings → 徽章 / Badges. Earned ones full-color, locked ones
/// silhouette. Tapping a locked badge silently unlocks "Curious Cat"
/// (meta easter egg).
struct BadgesView: View {
    @EnvironmentObject var auth: AuthService
    @EnvironmentObject var loc: Localizer
    @State private var data: BadgesResponse?
    @State private var error: String?
    @State private var loading = false
    @State private var selected: BadgeItem?

    var body: some View {
        ZStack {
            HU.C.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Spacer().frame(height: 4)

                    if let d = data {
                        VStack(alignment: .leading, spacing: 6) {
                            Eyebrow(text: "you have")
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(d.earned_count)")
                                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                                    .foregroundStyle(HU.C.ink)
                                Text("/ \(d.total_visible)")
                                    .font(HU.body()).foregroundStyle(HU.C.muted)
                                Spacer()
                            }
                            LText("解锁多少, 哪些惊喜没碰到, 你自己看。",
                                  "How many you've found. What's still hiding.")
                                .font(HU.small()).foregroundStyle(HU.C.muted)
                        }
                        .padding(.horizontal, 24)

                        // Earned section
                        let earned = d.badges.filter { $0.earned }
                        if !earned.isEmpty {
                            sectionHeader(zh: "已解锁", en: "Earned", subtitle: nil)
                            grid(badges: earned)
                        }

                        // Locked (visible non-secret) section
                        let locked = d.badges.filter { !$0.earned }
                        if !locked.isEmpty {
                            sectionHeader(
                                zh: "未解锁", en: "Locked",
                                subtitle: T("有些是秘密的, 不在这里 — 触发了才出现。",
                                           "Some are secret. They show up when you trip them.")
                            )
                            grid(badges: locked)
                        }

                        if d.badges.isEmpty {
                            Text(T("一个都还没。多用点 app 就好。",
                                   "Nothing yet. Use the app a little."))
                            .font(HU.body()).foregroundStyle(HU.C.muted)
                            .padding(.horizontal, 24).padding(.vertical, 30)
                        }
                    } else if loading {
                        ProgressView().tint(HU.C.muted).frame(maxWidth: .infinity).padding(40)
                    } else if let error = error {
                        Text(error).font(HU.small()).foregroundStyle(HU.C.accent)
                            .padding(.horizontal, 24)
                    }

                    Spacer().frame(height: 40)
                }
                .padding(.vertical, 12)
            }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(T("徽章", "Badges")).font(HU.title(.bold)).foregroundStyle(HU.C.ink)
            }
        }
        .toolbarBackground(HU.C.bg, for: .navigationBar)
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $selected) { badge in
            BadgeDetailSheet(badge: badge)
                .presentationDetents([.medium])
        }
    }

    private func sectionHeader(zh: String, en: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: en.lowercased())
            if let s = subtitle {
                Text(s).font(HU.small()).foregroundStyle(HU.C.muted).lineSpacing(2)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
    }

    private func grid(badges: [BadgeItem]) -> some View {
        let columns = [GridItem(.adaptive(minimum: 90, maximum: 110), spacing: 12)]
        return LazyVGrid(columns: columns, spacing: 12) {
            ForEach(badges) { b in
                Button {
                    selected = b
                    if !b.earned {
                        // Curious Cat — silent server call, ignore failures.
                        Task { await curiousTap() }
                    }
                } label: {
                    BadgeChip(badge: b, lang: loc.lang)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }

    private func load() async {
        guard let session = auth.session else { return }
        loading = true
        defer { loading = false }
        do {
            self.data = try await APIClient.shared.get(
                "/v1/app/me/badges", sessionToken: session.sessionToken
            )
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func curiousTap() async {
        guard let session = auth.session else { return }
        struct Empty: Encodable {}
        struct Resp: Decodable {}
        do {
            let _: Resp = try await APIClient.shared.post(
                "/v1/app/me/badges/curious-tap",
                body: Empty(),
                sessionToken: session.sessionToken
            )
        } catch {}
        await load()
    }
}

private struct BadgeChip: View {
    let badge: BadgeItem
    let lang: AppLanguage

    var body: some View {
        let name = lang == .zh ? badge.name_zh : badge.name_en
        VStack(spacing: 6) {
            Text(badge.icon)
                .font(.system(size: 36))
                .opacity(badge.earned ? 1 : 0.25)
                .grayscale(badge.earned ? 0 : 1)
                .frame(width: 64, height: 64)
                .background(
                    Circle().fill(badge.earned ? HU.C.accent.opacity(0.10) : HU.C.line.opacity(0.5))
                )
            Text(name)
                .font(HU.small(.medium))
                .foregroundStyle(badge.earned ? HU.C.ink : HU.C.muted.opacity(0.7))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
        }
    }
}

private struct BadgeDetailSheet: View {
    let badge: BadgeItem
    @EnvironmentObject var loc: Localizer

    var body: some View {
        let name = loc.lang == .zh ? badge.name_zh : badge.name_en
        let desc = loc.lang == .zh ? badge.description_zh : badge.description_en
        ZStack {
            HU.C.bg.ignoresSafeArea()
            VStack(spacing: 18) {
                Spacer().frame(height: 24)

                Text(badge.icon)
                    .font(.system(size: 80))
                    .opacity(badge.earned ? 1 : 0.3)
                    .grayscale(badge.earned ? 0 : 1)

                Text(name)
                    .font(HU.display())
                    .foregroundStyle(HU.C.ink)
                    .multilineTextAlignment(.center)

                Text(desc)
                    .font(HU.body())
                    .foregroundStyle(HU.C.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 32)

                if badge.earned, let earned = badge.earned_at {
                    Text(T("解锁于 \(formatDate(earned))",
                           "Earned \(formatDate(earned))"))
                        .font(HU.small()).foregroundStyle(HU.C.muted)
                } else {
                    Text(T("尚未解锁", "Locked"))
                        .font(HU.small()).foregroundStyle(HU.C.muted)
                }
                Spacer()
            }
        }
    }

    private func formatDate(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: iso) {
            let r = RelativeDateTimeFormatter()
            r.unitsStyle = .abbreviated
            return r.localizedString(for: d, relativeTo: Date())
        }
        return iso
    }
}
