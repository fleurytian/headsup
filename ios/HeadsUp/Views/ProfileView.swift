import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var auth: AuthService
    @EnvironmentObject var loc: Localizer
    @State private var data: MyDataPayload?
    @State private var badges: BadgesResponse?

    var body: some View {
        ZStack {
            HU.C.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Spacer().frame(height: 4)

                    VStack(alignment: .leading, spacing: 8) {
                        Eyebrow(text: "profile")
                        Text(T("你的 HeadsUp", "Your HeadsUp"))
                            .font(HU.display())
                            .foregroundStyle(HU.C.ink)
                    }
                    .padding(.horizontal, 24)

                    HStack(spacing: 12) {
                        profileStat(
                            value: badges.map { "\($0.earned_count)/\($0.total_visible)" } ?? "-",
                            label: T("徽章", "badges")
                        )
                        profileStat(
                            value: data?.response_rate.map { String(format: "%.0f%%", $0 * 100) } ?? "-",
                            label: T("响应率", "response rate")
                        )
                    }
                    .padding(.horizontal, 16)

                    VStack(alignment: .leading, spacing: 0) {
                        NavigationLink(destination: BadgesView()) {
                            profileRow(zh: "徽章", en: "Badges", icon: "rosette")
                        }
                        Rectangle().fill(HU.C.line).frame(height: 1).padding(.leading, 16)
                        NavigationLink(destination: MyDataView()) {
                            profileRow(zh: "统计", en: "Stats", icon: "chart.bar.fill")
                        }
                    }
                    .card()
                    .padding(.horizontal, 16)

                    Spacer().frame(height: 40)
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
    }

    private func profileStat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(HU.display())
                .foregroundStyle(HU.C.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(label)
                .font(HU.eyebrow())
                .tracking(2)
                .foregroundStyle(HU.C.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .card()
    }

    private func profileRow(zh: String, en: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(HU.C.accent)
                .frame(width: 22)
            Text(T(zh, en))
                .font(HU.body())
                .foregroundStyle(HU.C.ink)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.medium))
                .foregroundStyle(HU.C.muted.opacity(0.7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func load() async {
        guard let session = auth.session else { return }
        async let d: MyDataPayload? = try? APIClient.shared.get(
            "/v1/app/me/data", sessionToken: session.sessionToken
        )
        async let b: BadgesResponse? = try? APIClient.shared.get(
            "/v1/app/me/badges", sessionToken: session.sessionToken
        )
        data = await d
        badges = await b
    }
}
