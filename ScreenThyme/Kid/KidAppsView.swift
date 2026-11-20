import SwiftUI
import ThymeCore

/// The apps and websites this phone used in the last 30 days, most used today first; each opens its details.
struct KidAppsView: View {
    private struct Row: Identifiable {
        var item: TrackedItem
        /// The scan's item for the same app, whose token Apple draws with the app's real name and icon.
        var shown: TrackedItem
        var today: Double
        var month: Double
        var id: UUID { item.id }
    }

    @State private var rows: [Row]?
    @State private var heatmap: UsageHeatmap?

    var body: some View {
        List {
            if let heatmap, !heatmap.isEmpty {
                Section {
                    UsageHeatmapView(heatmap: heatmap)
                } header: {
                    Text("When")
                } footer: {
                    Text("All apps. " + UsageHeatmapView.footer)
                }
            }
            ForEach([ItemKind.app, .domain], id: \.self) { kind in
                let group = (rows ?? []).filter { $0.item.kind == kind }
                if !group.isEmpty {
                    Section(kind.pluralTitle) {
                        ForEach(group) { row in
                            NavigationLink { AppDetailsView(item: row.item) } label: {
                                LabeledContent {
                                    Text(row.today > 0 ? AppDetailsView.time(row.today) : "").monospacedDigit()
                                } label: {
                                    ItemName(item: row.shown)
                                    Text("\(AppDetailsView.time(row.month)) in 30 days")
                                }
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if rows?.isEmpty == true {
                ContentUnavailableView("No apps used yet", systemImage: "square.grid.2x2",
                                       description: Text("Apps show up here once this phone has shared some use."))
            }
        }
        .navigationTitle("Apps")
        .bugButton()
        .task {
            load()
            // Apps and websites new since launch; the rows redraw as their names and icons arrive.
            await AppCatalog.shared.lookUp(AppGroup.loadItems())
        }
        .refreshable { load() }
    }

    private func load() {
        let items = AppGroup.loadItems()
        let today = DayKey(Date())
        let since = today.adding(days: -(AppDetails.usageDays - 1))
        var todaySeconds: [UUID: Double] = [:]
        var monthSeconds: [UUID: Double] = [:]
        let samples = AppGroup.samples.readAll()
        let byDay = Dictionary(grouping: samples, by: \.day)
        let websites = Set(items.filter { $0.kind == .domain }.map(\.id))
        heatmap = UsageHeatmap.build(today: today, now: Date(), samples: { byDay[$0] ?? [] },
                                     counts: { !websites.contains($0.itemID) })
        for sample in samples where sample.day >= since {
            monthSeconds[sample.itemID, default: 0] += sample.seconds
            if sample.day == today { todaySeconds[sample.itemID, default: 0] += sample.seconds }
        }
        let scanned = Dictionary(items.filter { $0.isScanned && $0.tokenData != nil }.compactMap { item in item.match.map { ($0, item) } },
                                 uniquingKeysWith: { a, b in a.id.uuidString < b.id.uuidString ? a : b })
        rows = items.filter { !$0.isScanned && $0.kind != .category && (monthSeconds[$0.id] ?? 0) >= 30 }
            .map { Row(item: $0, shown: scanned[$0.id] ?? $0, today: todaySeconds[$0.id] ?? 0, month: monthSeconds[$0.id] ?? 0) }
            .sorted { ($0.today, $0.month) > ($1.today, $1.month) }
    }
}
