import SwiftUI
import ThymeCore
import UniformTypeIdentifiers

/// The replay tool (PLAN.md §7.2): re-upload a recorded or synthetic day under any (fake) kid.
struct ReplayView: View {
    @Environment(AppModel.self) private var model
    @State private var runner = ReplayRunner()

    @State private var scenario: SyntheticScenario? = .schoolDay
    @State private var imported: Trace?
    @State private var importing = false
    @State private var useJournal = false
    @State private var date = Date()
    @State private var kidID: UUID?
    @State private var newKidName = "Leo"
    @State private var speed = Speed.instant
    @State private var destination = ReplayRunner.Destination.local

    enum Speed: String, CaseIterable, Identifiable {
        case instant = "Instant", realTime = "Real time", fast = "60×"
        var id: String { rawValue }
        var value: ReplaySpeed {
            switch self {
            case .instant: .instant
            case .realTime: .realTime
            case .fast: .accelerated(60)
            }
        }
    }

    var body: some View {
        Form {
            Section("Source") {
                Picker("Synthetic day", selection: $scenario) {
                    Text("None").tag(SyntheticScenario?.none)
                    ForEach(SyntheticScenario.allCases) { Text($0.title).tag(SyntheticScenario?.some($0)) }
                }
                .onChange(of: scenario) { if scenario != nil { imported = nil; useJournal = false } }
                Toggle("This phone's journal for the chosen day", isOn: $useJournal)
                    .onChange(of: useJournal) { if useJournal { scenario = nil; imported = nil } }
                Button(imported.map { "Imported \($0.kid.displayName) · \($0.day.description)" } ?? "Import trace file…") {
                    importing = true
                }
            }
            Section {
                DatePicker("Day", selection: $date, displayedComponents: .date)
                Picker("Kid", selection: $kidID) {
                    Text("New test kid").tag(UUID?.none)
                    ForEach(model.data.sortedKids) { Text($0.displayName).tag(UUID?.some($0.id)) }
                }
                if kidID == nil {
                    TextField("Name", text: $newKidName)
                }
                Picker("Speed", selection: $speed) {
                    ForEach(Speed.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Send to", selection: $destination) {
                    Text("This phone only").tag(ReplayRunner.Destination.local)
                    Text("iCloud (family)").tag(ReplayRunner.Destination.cloud)
                }
            } header: {
                Text("Target")
            } footer: {
                Text("\"This phone only\" works in the Simulator without iCloud. Real time sends each fire when the clock reaches it; 60× keeps the timestamps but delivers fast, to watch alerts arrive.")
            }
            Section {
                if runner.isRunning {
                    ProgressView(value: Double(runner.sent), total: Double(max(runner.total, 1)))
                    Text("\(runner.sent) / \(runner.total) fires")
                    Button("Stop", role: .destructive) { runner.cancel() }
                } else {
                    Button("Replay") { start() }
                        .disabled(destination == .cloud && model.config.family == nil)
                }
                if let status = runner.status {
                    Text(status).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Replay")
        .bugButton()
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                imported = try Trace.decode(Data(contentsOf: url))
                scenario = nil
                useJournal = false
            } catch {
                model.show(error)
            }
        }
    }

    private func start() {
        let day = DayKey(date)
        let kid = kidID.flatMap { model.data.kids[$0] }
            ?? Kid(displayName: newKidName, colorIndex: model.data.kids.count, isTest: true)
        let trace: Trace
        if let imported {
            trace = imported
        } else if useJournal {
            guard let url = try? model.exportTrace(day: day), let data = try? Data(contentsOf: url),
                  let recorded = try? Trace.decode(data) else {
                model.message = "No journal for this phone (set up a kid identity first)."
                return
            }
            trace = recorded
        } else if let scenario {
            trace = scenario.trace(kid: kid, day: day)
        } else {
            return
        }
        kidID = kid.id
        runner.run(trace: trace, kid: kid, day: day, speed: speed.value, destination: destination, model: model)
    }
}

@MainActor @Observable
final class ReplayRunner {
    enum Destination: Hashable { case local, cloud }

    private(set) var isRunning = false
    private(set) var sent = 0
    private(set) var total = 0
    private(set) var status: String?
    private var task: Task<Void, Never>?

    func run(trace: Trace, kid: Kid, day: DayKey, speed: ReplaySpeed, destination: Destination, model: AppModel) {
        let moved = Replay.retarget(trace, to: kid, day: day)
        let fires = moved.fires()
        let alertsByTime = Self.alerts(for: moved, rules: model.data.rules(for: kid.id))
        // Fires and samples interleaved by time, as the kid's phone would send them.
        let events = (fires.map { (at: $0.firedAt, fire: Optional($0), sample: UsageSample?.none) }
            + moved.samples.map { (at: $0.end, fire: UsageFire?.none, sample: Optional($0)) })
            .sorted { $0.at < $1.at }
        let delays = Replay.delays(for: events.map(\.at), speed: speed, now: Date())
        total = events.count
        sent = 0
        isRunning = true
        status = nil

        task = Task {
            defer { isRunning = false }
            do {
                try await send(IngestBatch(kids: [kid], items: moved.items, epochs: moved.epoch.map { [$0] } ?? []),
                               to: destination, model: model)
                let start = Date()
                // Batch records that are due within the same second.
                let groups = Dictionary(grouping: zip(delays, events), by: { Int($0.0) }).sorted { $0.key < $1.key }
                for (second, group) in groups {
                    let wait = start.addingTimeInterval(Double(second)).timeIntervalSinceNow
                    if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                    let batchFires = group.compactMap(\.1.fire)
                    let batchAlerts = batchFires.flatMap { alertsByTime[$0.firedAt] ?? [] }
                    try await send(IngestBatch(fires: batchFires, samples: group.compactMap(\.1.sample), alerts: batchAlerts),
                                   to: destination, model: model)
                    sent += group.count
                }
                status = "Replayed \(fires.count) fires, \(moved.samples.count) samples and \(alertsByTime.values.joined().count) alerts as \(kid.displayName) on \(day)."
            } catch is CancellationError {
                status = "Stopped after \(sent) records."
            } catch {
                status = error.localizedDescription
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func send(_ batch: IngestBatch, to destination: Destination, model: AppModel) async throws {
        switch destination {
        case .local:
            for alert in model.data.ingest(batch) { Notifier.post(alert) }
        case .cloud:
            guard let store = model.store else { return }
            try await store.save(batch.kids)
            try await store.save(batch.items)
            try await store.save(batch.epochs)
            try await store.save(batch.fires)
            try await store.save(batch.samples)
            try await store.save(batch.alerts)
        }
    }

    /// What the kid's extension would have alerted at each wake (a total fire and the samples ending with it).
    private static func alerts(for trace: Trace, rules: [Rule]) -> [Date: [AlertRecord]] {
        let items = Dictionary(uniqueKeysWithValues: trace.items.map { ($0.id, $0) })
        let engine = RuleEngine(kidID: trace.kid.id, kidName: trace.kid.displayName, items: items)
        var state = MonitorDayState(day: trace.day)
        var cumulative: [UUID: Double] = [:]
        var seen = Set<UUID>()
        let samplesByEnd = Dictionary(grouping: trace.samples, by: \.end)
        var result: [Date: [AlertRecord]] = [:]
        for entry in trace.entries {
            guard let parsed = entry.parsedEvent, parsed.itemID == nil else { continue }
            var interval: [UUID: Double] = [:]
            for sample in samplesByEnd[entry.at] ?? [] {
                interval[sample.itemID, default: 0] += sample.seconds
                cumulative[sample.itemID, default: 0] += sample.seconds
            }
            let newItems = interval.keys.filter { seen.insert($0).inserted }
            let wake = WakeObservation(at: entry.at, totalMinute: parsed.minute, itemSeconds: cumulative,
                                       intervalSeconds: interval, newItems: Array(newItems))
            let alerts = engine.process(wake, state: &state, rules: rules)
            if !alerts.isEmpty { result[entry.at] = alerts }
        }
        return result
    }
}
