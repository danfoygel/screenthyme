import DeviceActivity
import ExtensionKit
import FamilyControls
import ManagedSettings
import SwiftUI

/// Apple's own per-app numbers for a day, rendered on the kid's phone next to ours (PLAN.md §4.9, §7).
/// Sandboxed by Apple: it can show data but can't send or store it anywhere.
@main
struct ThymeReport: @preconcurrency DeviceActivityReportExtension {
    @MainActor var body: some DeviceActivityReportScene {
        AppTotalsReport { report in
            AppTotalsView(report: report)
        }
        ComparisonReport { report in
            ComparisonView(report: report)
        }
    }
}

extension DeviceActivityReport.Context {
    static let appTotals = Self("appTotals")
}

/// Tokens are immutable values; ManagedSettings just doesn't mark them Sendable.
struct AppTotalsData: @unchecked Sendable {
    struct Row: Identifiable {
        let id: Int
        let app: ApplicationToken?
        let site: WebDomainToken?
        let name: String
        let seconds: TimeInterval
    }

    var totalSeconds: TimeInterval = 0
    var segments = 0
    var rows: [Row] = []
}

// The SDK requirement predates strict concurrency; the scene is only driven on the main actor.
struct AppTotalsReport: @preconcurrency DeviceActivityReportScene {
    let context: DeviceActivityReport.Context = .appTotals
    let content: (AppTotalsData) -> AppTotalsView

    nonisolated func makeConfiguration(representing data: DeviceActivityResults<DeviceActivityData>) async -> AppTotalsData {
        var report = AppTotalsData()
        var apps: [ApplicationToken?: (name: String, seconds: TimeInterval)] = [:]
        var sites: [WebDomainToken?: (name: String, seconds: TimeInterval)] = [:]
        for await device in data {
            for await segment in device.activitySegments {
                report.segments += 1
                report.totalSeconds += segment.totalActivityDuration
                for await category in segment.categories {
                    for await app in category.applications {
                        let name = app.application.localizedDisplayName ?? app.application.bundleIdentifier ?? "App"
                        apps[app.application.token, default: (name, 0)].seconds += app.totalActivityDuration
                    }
                    for await site in category.webDomains {
                        sites[site.webDomain.token, default: (site.webDomain.domain ?? "Website", 0)].seconds += site.totalActivityDuration
                    }
                }
            }
        }
        let appRows = apps.map { (app: $0.key, site: WebDomainToken?.none, name: $0.value.name, seconds: $0.value.seconds) }
        let siteRows = sites.map { (app: ApplicationToken?.none, site: $0.key, name: $0.value.name, seconds: $0.value.seconds) }
        report.rows = (appRows + siteRows)
            .filter { $0.seconds >= 60 }
            .sorted { $0.seconds > $1.seconds }
            .enumerated()
            .map { AppTotalsData.Row(id: $0.offset, app: $0.element.app, site: $0.element.site, name: $0.element.name,
                                     seconds: $0.element.seconds) }
        return report
    }
}

struct AppTotalsView: View {
    let report: AppTotalsData

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Always drawn, so an empty report is distinguishable from one that didn't render.
                Text("Apple: \(duration(report.totalSeconds)) total · \(report.rows.count) apps and sites over 1 min · \(report.segments) segments")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(report.rows) { row in
                    HStack {
                        if let app = row.app {
                            Label(app)
                        } else if let site = row.site {
                            Label(site)
                        } else {
                            Text(row.name)
                        }
                        Spacer()
                        Text(duration(row.seconds)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}
