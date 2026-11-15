import DeviceActivity
import SwiftUI
import ThymeCore

/// The spike workbench (PLAN.md §6 S1, S3, S6): ladders, raw fires, our reconstruction vs Apple's numbers.
struct KidDebugView: View {
    @Environment(AppModel.self) private var model
    @State private var day = DayKey(Date())
    @State private var exportURL: URL?

    var body: some View {
        let entries = AppGroup.journal.entries(on: day)
        let input = model.config.dayInput(day)
        let timeline = Reconstructor.build(input)
        let items = Dictionary(uniqueKeysWithValues: model.config.items.map { ($0.id, $0) })
        Form {
            Section {
                HStack {
                    Button { day = day.adding(days: -1) } label: { Image(systemName: "chevron.left") }
                    Spacer()
                    Text(day.description).monospacedDigit()
                    Spacer()
                    Button { day = day.adding(days: 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(day >= DayKey(Date()))
                }
                .buttonStyle(.borderless)
            }
            Section("Rolling ladders (S1)") {
                ladderInfo
                Button("Re-register current scan") {
                    guard let kid = model.config.kid, let epoch = model.config.epoch else { return }
                    do {
                        _ = try Roller.registerAll(epochID: epoch.id, kid: kid, items: model.config.items.filter(\.active))
                    } catch { model.show(error) }
                }
                Button("Stop all monitoring", role: .destructive) { model.stopMonitoring() }
            }
            Section("Reconstruction") {
                LabeledContent("Total", value: Format.minutes(timeline.totalMinutes))
                LabeledContent("Unexplained", value: Format.minutes(timeline.unexplainedMinutes))
                LabeledContent("Before tracking started", value: Format.minutes(timeline.preTrackingMinutes))
                LabeledContent("Suspect fires", value: "\(timeline.suspectFires)")
                LabeledContent("Unfulfilled minutes", value: "\(timeline.unfulfilledMinutes)")
                TimelineLanes(timeline: timeline, items: items, dayStart: day.start())
                ForEach(timeline.totals.sorted { $0.value.lowerMinutes > $1.value.lowerMinutes }, id: \.key) { id, total in
                    LabeledContent { Text(Format.range(total)).monospacedDigit() } label: { ItemName(item: items[id]) }
                }
            }
            Section("Apple's data-access option (S4)") {
                NavigationLink("Data access test") { DataAccessView() }
            }
            Section("Apple's numbers (on this phone only)") {
                NavigationLink("Compare with Apple (S1c)") { AppleReportView(day: day, context: "comparison") }
                NavigationLink("Apple's report for \(day.description)") { AppleReportView(day: day, context: "appTotals") }
            }
            Section("Upload (S3)") {
                LabeledContent("Waiting", value: "\(Uploader.backlogCount())")
                Button("Upload now") { Task { await model.flush() } }
            }
            if let kid = model.config.kid {
                Section("Our battery use (\(EnergyMeter.deviceModel))") {
                    EnergyRows(report: EnergyMeter.report(kid: kid, day: day))
                }
            }
            Section("Raw fires · \(entries.count)") {
                Button("Export day as trace") {
                    do { exportURL = try model.exportTrace(day: day) } catch { model.show(error) }
                }
                if let exportURL {
                    ShareLink("Share \(exportURL.lastPathComponent)", item: exportURL)
                }
                ForEach(entries.suffix(200).reversed()) { entry in
                    HStack {
                        Text(entry.at.formatted(date: .omitted, time: .standard)).monospacedDigit()
                        Spacer()
                        rawLabel(entry, items: items)
                    }
                    .font(.caption)
                }
            }
        }
        .navigationTitle("Debug")
    }

    @ViewBuilder
    private var ladderInfo: some View {
        let active = DeviceActivityCenter().activities.map(\.rawValue).sorted()
        LabeledContent("Epoch", value: model.config.epoch.map { String($0.id.uuidString.prefix(8)) } ?? "none")
        LabeledContent("Planned schedules", value: "\(model.config.epoch?.activityNames.count ?? 0)")
        LabeledContent("Registered schedules", value: "\(active.count)")
        ForEach(active, id: \.self) { name in
            let count = DeviceActivityCenter().events(for: DeviceActivityName(name)).count
            LabeledContent(name, value: "\(count) events").font(.caption)
        }
    }

    @ViewBuilder
    private func rawLabel(_ entry: JournalEntry, items: [UUID: TrackedItem]) -> some View {
        switch (entry.kind, entry.parsedEvent) {
        case let (.threshold, parsed?):
            if let id = parsed.itemID {
                HStack(spacing: 4) {
                    ItemName(item: items[id], showIcon: false)
                    Text("\(parsed.minute) min")
                }
            } else {
                Text("total \(parsed.minute) min")
            }
        case (.note, _):
            Text(entry.event ?? "").foregroundStyle(.orange)
        default:
            Text("\(entry.kind.rawValue) \(entry.activity)").foregroundStyle(.secondary)
        }
    }
}

/// Apple's own numbers, drawn by the ThymeReport extension. Full screen: the remote view doesn't size well in a row.
struct AppleReportView: View {
    let day: DayKey
    let context: String

    var body: some View {
        DeviceActivityReport(.init(context),
                             filter: DeviceActivityFilter(segment: .daily(during: DateInterval(start: day.start(),
                                                                                                end: min(day.end(), Date())))))
            .navigationTitle("Apple's numbers")
            .navigationBarTitleDisplayMode(.inline)
    }
}
