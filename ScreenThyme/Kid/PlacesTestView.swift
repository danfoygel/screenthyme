import SwiftUI
import ThymeCore
import UIKit

/// The location test (PLAN.md §19): mark places, then see what iOS reported, how late, and today's use by place.
struct PlacesTestView: View {
    @Environment(AppModel.self) private var model
    @State private var watcher = PlaceWatcher.shared
    @State private var name = "Home"
    @State private var marking = false
    @State private var enabled = PlaceWatcher.shared.isEnabled

    var body: some View {
        let now = Date()
        let day = DayKey(now)
        let events = watcher.events.filter { DayKey($0.at) == day || DayKey($0.observedAt) == day }
        let stays = PlaceStays.build(watcher.events, places: watcher.places, now: now)
            .filter { $0.end > day.start() }
        let timeline = Reconstructor.build(model.config.dayInput(day))
        let byPlace = PlaceStays.usage(timeline.blocks, stays: stays)
        let items = Dictionary(AppGroup.loadItems().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        Form {
            Section {
                Toggle("Watch places", isOn: $enabled)
                    .onChange(of: enabled) { _, on in watcher.setEnabled(on) }
                LabeledContent("Location access", value: watcher.authorization.label)
                if let problem = watcher.problem {
                    Text(problem).foregroundStyle(.orange)
                }
                if enabled, watcher.authorization != .authorizedAlways {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
            } footer: {
                Text("iOS watches the fences and visits itself and wakes ScreenThyme only when something changes. "
                     + "It all stays on this phone.")
            }
            Section {
                ForEach(watcher.places) { place in
                    LabeledContent(place.name) {
                        VStack(alignment: .trailing) {
                            Text("\(Int(place.radius)) m")
                            if let region = watcher.regions[place.id] {
                                Text("Region: \(region.state) as of \(when(region.since))").font(.caption)
                            }
                        }
                    }
                }
                .onDelete { offsets in offsets.map { watcher.places[$0] }.forEach(watcher.remove) }
                HStack {
                    TextField("Name", text: $name)
                    Button(marking ? "Finding…" : "Mark this spot") {
                        marking = true
                        Task {
                            do { try await watcher.markHere(name: name) } catch { model.show(error) }
                            marking = false
                        }
                    }
                    .disabled(marking || name.isEmpty || !enabled || watcher.places.count >= 20)
                }
            } header: {
                Text("Places")
            } footer: {
                Text("“Region:” is what iOS's region monitoring last said about the place.")
            }
            Section("Today by place") {
                ForEach(byPlace.sorted { total($0.value) > total($1.value) }, id: \.key) { whereabouts, apps in
                    DisclosureGroup {
                        ForEach(apps.sorted { $0.value > $1.value }.prefix(8), id: \.key) { id, seconds in
                            LabeledContent { Text(minutes(seconds)).monospacedDigit() } label: { ItemName(item: items[id]) }
                        }
                    } label: {
                        LabeledContent(label(whereabouts), value: minutes(total(apps)))
                    }
                }
            }
            Section("Stays · \(stays.count)") {
                ForEach(stays.reversed(), id: \.self) { stay in
                    LabeledContent(label(stay.whereabouts),
                                   value: "\(when(stay.start))–\(stay.isOpen ? "now" : when(stay.end))")
                        .monospacedDigit()
                }
            }
            Section {
                ForEach(events.reversed()) { event in
                    HStack {
                        Text(event.at.formatted(date: .omitted, time: .standard)).monospacedDigit()
                        Text(describe(event))
                        Spacer()
                        Text("+\(late(event))").foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.caption)
                }
            } header: {
                Text("Events today · \(events.count)")
            } footer: {
                Text("+ is how long after it happened iOS told ScreenThyme.")
            }
            Section("Diagnostics") {
                ForEach(Array(watcher.diagnostics.reversed().enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption2).monospaced()
                }
            }
            Section {
                Button("Clear events", role: .destructive) { watcher.clearEvents() }
            }
        }
        .navigationTitle("Places")
        .bugButton()
    }

    private func label(_ whereabouts: Whereabouts) -> String {
        switch whereabouts {
        case let .place(id): watcher.places.first { $0.id == id }?.name ?? "Removed place"
        case .elsewhere: "Elsewhere"
        case .unknown: "Unknown"
        }
    }

    private func describe(_ event: PlaceEvent) -> String {
        let place = event.place.map { label(.place($0)) } ?? ""
        switch event.kind {
        case .enter: return "entered \(place)\(source(event))"
        case .exit: return "left \(place)\(source(event))"
        case .visit:
            let accuracy = event.accuracy.map { " ±\(Int($0)) m" } ?? ""
            return "visit until \(event.departure.map(Format.time) ?? "…")\(accuracy)"
        }
    }

    private func source(_ event: PlaceEvent) -> String {
        event.source == .region ? " (region)" : " (monitor)"
    }

    /// A time today; with the day otherwise.
    private func when(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? Format.time(date) : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    private func late(_ event: PlaceEvent) -> String {
        let seconds = max(0, Int(event.delay))
        return seconds < 120 ? "\(seconds) s" : "\(seconds / 60) min"
    }

    private func total(_ apps: [UUID: Double]) -> Double { apps.values.reduce(0, +) }

    private func minutes(_ seconds: Double) -> String { Format.minutes(Int((seconds / 60).rounded())) }
}
