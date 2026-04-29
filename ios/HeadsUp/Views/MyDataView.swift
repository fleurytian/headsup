import SwiftUI

struct MyDataPayload: Codable {
    let total_received: Int
    let total_replied: Int
    let response_rate: Double?
    let median_response_seconds: Double?
    let hour_histogram: [Int]
    let since: Date?
}

/// Settings → 我的数据 / Your Data.
/// Pulls /v1/app/me/data; renders 4 stat boxes + a 24-hour activity bar chart.
struct MyDataView: View {
    @EnvironmentObject var auth: AuthService
    @EnvironmentObject var loc: Localizer
    @State private var data: MyDataPayload?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        ZStack {
            HU.C.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Spacer().frame(height: 4)

                    if let d = data {
                        statsGrid(d)
                        histogramCard(d)
                    } else if loading {
                        ProgressView().tint(HU.C.muted).frame(maxWidth: .infinity).padding(40)
                    } else if let e = error {
                        Text(e).font(HU.small()).foregroundStyle(HU.C.accent).padding(.horizontal, 24)
                    }

                    Spacer().frame(height: 40)
                }
                .padding(.vertical, 12)
            }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(T("我的数据", "Your Data")).font(HU.title(.bold)).foregroundStyle(HU.C.ink)
            }
        }
        .toolbarBackground(HU.C.bg, for: .navigationBar)
        .task { await load() }
        .refreshable { await load() }
    }

    private func statsGrid(_ d: MyDataPayload) -> some View {
        let pct: String = d.response_rate.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
        let median: String = formatDuration(d.median_response_seconds)

        return VStack(spacing: 12) {
            HStack(spacing: 12) {
                statBox(value: "\(d.total_received)", label: T("总收到", "received"))
                statBox(value: "\(d.total_replied)",  label: T("总回复", "replied"))
            }
            HStack(spacing: 12) {
                statBox(value: pct,    label: T("响应率", "response rate"))
                statBox(value: median, label: T("中位响应时长", "median time"))
            }
        }
        .padding(.horizontal, 16)
    }

    private func statBox(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(HU.display()).foregroundStyle(HU.C.ink)
            Text(label).font(HU.eyebrow()).tracking(2).foregroundStyle(HU.C.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .card()
    }

    private func histogramCard(_ d: MyDataPayload) -> some View {
        let maxV = max(1, d.hour_histogram.max() ?? 1)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow(text: "by hour")
                Spacer()
                Text(T("你最常回应的时段", "Hours you reply"))
                    .font(HU.small()).foregroundStyle(HU.C.muted)
            }

            GeometryReader { geo in
                let barW = (geo.size.width - 23 * 3) / 24  // 24 bars, 3pt gaps
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(0..<24, id: \.self) { h in
                        let v = d.hour_histogram[h]
                        let height = max(2, geo.size.height * CGFloat(v) / CGFloat(maxV))
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(v == 0 ? HU.C.line : HU.C.accent.opacity(0.7))
                                .frame(width: barW, height: height)
                        }
                        .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
            .frame(height: 120)

            HStack {
                Text("0").font(.system(size: 9, design: .monospaced)).foregroundStyle(HU.C.muted)
                Spacer()
                Text("12").font(.system(size: 9, design: .monospaced)).foregroundStyle(HU.C.muted)
                Spacer()
                Text("23").font(.system(size: 9, design: .monospaced)).foregroundStyle(HU.C.muted)
            }
        }
        .padding(16)
        .card()
        .padding(.horizontal, 16)
    }

    private func formatDuration(_ secs: Double?) -> String {
        guard let s = secs else { return "—" }
        if s < 1 { return String(format: "%.1fs", s) }
        if s < 60 { return String(format: "%.0fs", s) }
        if s < 3600 { return String(format: "%.0fm", s / 60) }
        return String(format: "%.1fh", s / 3600)
    }

    private func load() async {
        guard let session = auth.session else { return }
        loading = true; defer { loading = false }
        do {
            self.data = try await APIClient.shared.get(
                "/v1/app/me/data", sessionToken: session.sessionToken
            )
        } catch {
            self.error = error.localizedDescription
        }
    }
}
