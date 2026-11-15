import DeviceActivity
import ExtensionKit
import FamilyControls
import ManagedSettings
import SwiftUI
import ThymeCore

/// S1(c) scoreboard: Apple's per-app minutes next to our reconstructed range for the same day, matched by token.
/// Only possible here: Apple's numbers never leave this extension. Ours are read from the App Group.
extension DeviceActivityReport.Context {
    static let comparison = Self("comparison")
}

/// Tokens are immutable values; ManagedSettings just doesn't mark them Sendable.
struct ComparisonData: @unchecked Sendable {
    enum Verdict {
        case match
        /// Our range is below Apple's minutes by this much.
        case under(Int)
        /// Our range is above Apple's minutes by this much.
        case over(Int)
        /// Apple has use for something our scan doesn't track.
        case untracked
    }

    struct Row: Identifiable {
        let id: Int
        let app: ApplicationToken?
        let site: WebDomainToken?
        let appleMinutes: Int
        let ours: String
        let verdict: Verdict
    }

    var day = ""
    var appleMinutes = 0
    var ourMinutes = 0
    var preTrackingMinutes = 0
    var rows: [Row] = []
    var problem: String?

    var compared: Int { rows.filter { if case .untracked = $0.verdict { false } else { true } }.count }
    var matched: Int { rows.filter { if case .match = $0.verdict { true } else { false } }.count }
}

struct ComparisonReport: @preconcurrency DeviceActivityReportScene {
    let context: DeviceActivityReport.Context = .comparison
    let content: (ComparisonData) -> ComparisonView

    nonisolated func makeConfiguration(representing data: DeviceActivityResults<DeviceActivityData>) async -> ComparisonData {
        var report = ComparisonData()
        var appleApps: [ApplicationToken: TimeInterval] = [:]
        var appleSites: [WebDomainToken: TimeInterval] = [:]
        var dayStart: Date?
        for await device in data {
            for await segment in device.activitySegments {
                dayStart = min(dayStart ?? segment.dateInterval.start, segment.dateInterval.start)
                report.appleMinutes += Int(segment.totalActivityDuration / 60)
                for await category in segment.categories {
                    for await app in category.applications {
                        if let token = app.application.token { appleApps[token, default: 0] += app.totalActivityDuration }
                    }
                    for await site in category.webDomains {
                        if let token = site.webDomain.token { appleSites[token, default: 0] += site.totalActivityDuration }
                    }
                }
            }
        }
        guard let dayStart else {
            report.problem = "Apple returned no data for this day."
            return report
        }
        let day = DayKey(dayStart)
        report.day = day.description

        let config = SharedConfig.load()
        guard !config.items.isEmpty else {
            report.problem = "Can't read ScreenThyme's scan from the App Group here."
            return report
        }
        let input = config.dayInput(day)
        guard !input.total.isEmpty else {
            report.problem = "Can't read ScreenThyme's journal for \(day) here (or it's empty)."
            return report
        }
        let timeline = Reconstructor.build(input)
        report.ourMinutes = timeline.totalMinutes
        report.preTrackingMinutes = timeline.preTrackingMinutes

        var ourApps: [ApplicationToken: TrackedItem] = [:]
        var ourSites: [WebDomainToken: TrackedItem] = [:]
        for item in config.items where item.active {
            guard let data = item.tokenData else { continue }
            switch item.kind {
            case .app: (try? JSONDecoder().decode(ApplicationToken.self, from: data)).map { ourApps[$0] = item }
            case .domain: (try? JSONDecoder().decode(WebDomainToken.self, from: data)).map { ourSites[$0] = item }
            case .category: break
            }
        }

        func row(_ id: Int, app: ApplicationToken?, site: WebDomainToken?, seconds: TimeInterval,
                 item: TrackedItem?) -> ComparisonData.Row {
            let apple = Int((seconds / 60).rounded())
            guard let item else {
                return .init(id: id, app: app, site: site, appleMinutes: apple, ours: "not tracked", verdict: .untracked)
            }
            let short = item.kind == .domain
            let total = timeline.totals[item.id]
            let lower = total?.lowerMinutes ?? 0
            let upper = total?.upperMinutes ?? input.spec.itemRemainder(after: 0, short: short)
            let openEnded = total?.openEnded ?? false
            let ours = openEnded ? "\(lower)+" : "\(lower)–\(upper)"
            // Apple rounds to whole minutes; allow one minute either way.
            let verdict: ComparisonData.Verdict = if apple < lower - 1 {
                .over(lower - apple)
            } else if !openEnded, apple > upper + 1 {
                .under(apple - upper)
            } else {
                .match
            }
            return .init(id: id, app: app, site: site, appleMinutes: apple, ours: ours, verdict: verdict)
        }

        var rows: [ComparisonData.Row] = []
        for (token, seconds) in appleApps where seconds >= 60 {
            rows.append(row(rows.count, app: token, site: nil, seconds: seconds, item: ourApps[token]))
        }
        for (token, seconds) in appleSites where seconds >= 60 {
            rows.append(row(rows.count, app: nil, site: token, seconds: seconds, item: ourSites[token]))
        }
        report.rows = rows.sorted { $0.appleMinutes > $1.appleMinutes }
        return report
    }
}

struct ComparisonView: View {
    let report: ComparisonData

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let problem = report.problem {
                    Text(problem).foregroundStyle(.orange)
                }
                Text("\(report.day) · Apple \(report.appleMinutes) min · ours \(report.ourMinutes) min (\(report.preTrackingMinutes) before tracking)")
                    .font(.footnote)
                Text("\(report.matched) of \(report.compared) tracked apps and sites match (±1 min)")
                    .font(.headline)
                ForEach(report.rows) { row in
                    HStack {
                        Group {
                            if let app = row.app { Label(app) } else if let site = row.site { Label(site) }
                        }
                        .lineLimit(1)
                        Spacer()
                        Text("\(row.appleMinutes)").monospacedDigit()
                        Text(row.ours).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                        verdict(row.verdict).frame(width: 44, alignment: .trailing)
                    }
                    .font(.subheadline)
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func verdict(_ verdict: ComparisonData.Verdict) -> some View {
        switch verdict {
        case .match: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case let .under(minutes): Text("−\(minutes)").foregroundStyle(.red)
        case let .over(minutes): Text("+\(minutes)").foregroundStyle(.orange)
        case .untracked: Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        }
    }
}
