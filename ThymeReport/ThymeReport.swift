import DeviceActivity
import ExtensionKit
import FamilyControls
import ManagedSettings
import SwiftUI

/// Apple's own per-app numbers for today, rendered on the kid's phone next to ours (PLAN.md §4.9, §7).
/// Sandboxed by Apple: it can show data but can't send or store it anywhere.
@main
struct ThymeReport: @preconcurrency DeviceActivityReportExtension {
    @MainActor var body: some DeviceActivityReportScene {
        AppTotalsReport { totals in
            AppTotalsView(totals: totals)
        }
    }
}

extension DeviceActivityReport.Context {
    static let appTotals = Self("appTotals")
}

/// Tokens are immutable values; ManagedSettings just doesn't mark them Sendable.
struct AppTotal: Identifiable, @unchecked Sendable {
    let id: Int
    let token: ApplicationToken?
    let name: String
    let duration: TimeInterval
}

// The SDK requirement predates strict concurrency; the scene is only driven on the main actor.
struct AppTotalsReport: @preconcurrency DeviceActivityReportScene {
    let context: DeviceActivityReport.Context = .appTotals
    let content: ([AppTotal]) -> AppTotalsView

    nonisolated func makeConfiguration(representing data: DeviceActivityResults<DeviceActivityData>) async -> [AppTotal] {
        var durations: [ApplicationToken?: (name: String, seconds: TimeInterval)] = [:]
        for await device in data {
            for await segment in device.activitySegments {
                for await category in segment.categories {
                    for await app in category.applications {
                        let key = app.application.token
                        let name = app.application.localizedDisplayName ?? app.application.bundleIdentifier ?? "App"
                        durations[key, default: (name, 0)].seconds += app.totalActivityDuration
                    }
                }
            }
        }
        return durations
            .sorted { $0.value.seconds > $1.value.seconds }
            .enumerated()
            .map { AppTotal(id: $0.offset, token: $0.element.key, name: $0.element.value.name, duration: $0.element.value.seconds) }
    }
}

struct AppTotalsView: View {
    let totals: [AppTotal]

    var body: some View {
        List(totals) { total in
            HStack {
                if let token = total.token {
                    Label(token)
                } else {
                    Text(total.name)
                }
                Spacer()
                Text(Duration.seconds(total.duration).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}
