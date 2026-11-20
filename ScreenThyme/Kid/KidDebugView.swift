import DeviceActivity
import SwiftUI
import ThymeCore

/// The capture workbench: the wake alarm, Apple's samples, the day as parents will see it, raw fires.
struct KidDebugView: View {
    @Environment(AppModel.self) private var model
    @State private var day = DayKey(Date())
    @State private var exportURL: URL?
    @AppStorage("timelineScale") private var timelineScale = 120.0

    var body: some View {
        let input = model.config.dayInput(day)
        let timeline = Reconstructor.build(input)
        let items = Dictionary(AppGroup.loadItems().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let entries = AppGroup.journal.entries(on: day)
        Form {
            Section {
                NavigationLink("Permissions") { PermissionsView() }
            }
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
            Section("Wake alarm") {
                let active = DeviceActivityCenter().activities.map(\.rawValue)
                LabeledContent("Registered", value: active.isEmpty ? "none" : active.joined(separator: ", "))
                if let activity = Roller.load() {
                    LabeledContent("Thresholds up to", value: "\(activity.upTo) min (\(activity.day))")
                    if activity.offset != 0 {
                        LabeledContent("iOS counts less by", value: "\(activity.offset) min")
                    }
                }
                Button("Re-register") { Task { await model.startMonitoring() } }
                Button("Stop monitoring", role: .destructive) { model.stopMonitoring() }
            }
            Section("Today as parents see it") {
                LabeledContent("Phone in use (total thresholds)", value: Format.minutes(timeline.totalMinutes))
                LabeledContent("Apps and sites (Apple)", value: Format.minutes(timeline.appMinutes))
                LabeledContent("Samples", value: "\(input.samples.count)")
                TimelineLanes(timeline: timeline, items: items, dayStart: day.start())
                NavigationLink("Day timeline") {
                    UsageCalendar(timeline: timeline, items: items, dayStart: day.start(), scale: $timelineScale)
                        .navigationTitle(day.description)
                        .bugButton()
                }
                ForEach(timeline.items.sorted { $0.value.seconds > $1.value.seconds }, id: \.key) { id, usage in
                    LabeledContent { Text(Format.minutes(usage.minutes)).monospacedDigit() } label: { ItemName(item: items[id]) }
                }
            }
            Section("Apple") {
                NavigationLink("Data access test") { DataAccessView() }
                NavigationLink("Apple's report for \(day.description)") { AppleReportView(day: day) }
                NavigationLink("Match scanned apps by screenshot") { TokenPairingView() }
                NavigationLink("Raw usage (\(input.samples.count) samples)") {
                    RawUsageView(items: items, samples: { day in AppGroup.samples.readAll().filter { $0.day == day } }, day: day)
                }
            }
            Section("Upload") {
                LabeledContent("Waiting", value: "\(Uploader.backlogCount())")
                Button("Sample and upload now") {
                    Task {
                        await model.sampleNow()
                        await model.flush()
                    }
                }
            }
            if let kid = model.config.kid {
                Section("Our battery use (\(EnergyMeter.deviceModel))") {
                    EnergyRows(report: EnergyMeter.report(kid: kid, day: day))
                }
            }
            Section("Journal · \(entries.count)") {
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
                        Text(label(entry)).foregroundStyle(entry.kind == .note ? .orange : .primary)
                    }
                    .font(.caption)
                }
            }
        }
        .navigationTitle("Debug")
        .bugButton()
    }

    private func label(_ entry: JournalEntry) -> String {
        switch (entry.kind, entry.parsedEvent) {
        case let (.threshold, parsed?): parsed.itemID == nil ? "total \(parsed.minute) min" : "old item fire"
        case (.note, _): entry.event ?? ""
        default: "\(entry.kind.rawValue) \(entry.activity)"
        }
    }
}

/// Apple's own numbers, drawn by the ThymeReport extension. Full screen: the remote view doesn't size well in a row.
struct AppleReportView: View {
    let day: DayKey

    var body: some View {
        DeviceActivityReport(.init("appTotals"),
                             filter: DeviceActivityFilter(segment: .daily(during: DateInterval(start: day.start(),
                                                                                                end: min(day.end(), Date())))))
            .navigationTitle("Apple's numbers")
            .bugButton()
            .navigationBarTitleDisplayMode(.inline)
    }
}
