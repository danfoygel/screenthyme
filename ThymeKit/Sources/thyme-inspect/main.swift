import Foundation
import ThymeCore

// Usage: thyme-inspect <journal-YYYY-MM-DD.jsonl> [samples.jsonl] [items.json] [Places/]
// Files as copied off a kid phone (App Group Library/ScreenThyme: Journal/, Outbox/samples.jsonl, items.json, and the
// location test's Places/, PLAN.md §19).
// Prints the day in the Mac's time zone, which should match the phone's.

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("usage: thyme-inspect <journal-YYYY-MM-DD.jsonl> [samples.jsonl] [items.json] [Places/]")
    exit(1)
}
let journalURL = URL(filePath: arguments[1])
let dayString = journalURL.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "journal-", with: "")
guard let day = DayKey(string: dayString) else {
    print("can't read the day from \(journalURL.lastPathComponent)")
    exit(1)
}
let entries = JSONLinesFile<JournalEntry>(url: journalURL).readAll()
let samples = arguments.count >= 3
    ? JSONLinesFile<UsageSample>(url: URL(filePath: arguments[2])).readAll().filter { $0.day == day } : []
let items: [UUID: TrackedItem] = {
    guard arguments.count >= 4, let data = try? Data(contentsOf: URL(filePath: arguments[3])),
          let list = try? JSONDecoder.thyme.decode([TrackedItem].self, from: data) else { return [:] }
    return Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
}()

@MainActor func name(_ id: UUID) -> String { items[id]?.displayName ?? String(id.uuidString.prefix(8)) }
func clock(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

let input = DayInput(entries: entries, samples: samples, dayStart: day.start())
let timeline = Reconstructor.build(input)

print("Day \(day): \(input.total.count) total fires, \(samples.count) samples, \(items.count) known items")
print("Total-ladder \(timeline.totalMinutes) min (\(timeline.preTrackingMinutes) before tracking) · Apple apps \(timeline.appMinutes) min · suspect \(timeline.suspectFires)")
print("Runs: " + timeline.runs.map { "\(clock($0.start))–\(clock($0.end))" }.joined(separator: ", "))
print("\nApps:")
for (id, usage) in timeline.items.sorted(by: { $0.value.seconds > $1.value.seconds }) {
    print("  \(name(id).padding(toLength: 22, withPad: " ", startingAt: 0)) \(usage.minutes) min  \(clock(usage.firstAt))–\(clock(usage.lastAt))")
}
print("\nBlocks:")
for block in timeline.blocks {
    print("  \(clock(block.start))–\(clock(block.end))  \(Int(block.seconds)) s  \(String(format: "%.0f%%", block.intensity * 100))  \(name(block.itemID))")
}

// The location test: where the phone was, and the blocks above split by place. No coordinates: visits are named by
// distance from the nearest place.
if arguments.count >= 5 {
    let directory = URL(filePath: arguments[4])
    let places = (try? Data(contentsOf: directory.appending(path: "places.json")))
        .flatMap { try? JSONDecoder.thyme.decode([Place].self, from: $0) } ?? []
    let events = JSONLinesFile<PlaceEvent>(url: directory.appending(path: "events.jsonl")).readAll()
    let now = min(Date(), day.end())
    func placeName(_ whereabouts: Whereabouts) -> String {
        switch whereabouts {
        case let .place(id): places.first { $0.id == id }?.name ?? "removed place"
        case .elsewhere: "Other locations"
        case .unknown: "While moving"
        }
    }
    func late(_ event: PlaceEvent) -> String {
        let seconds = Int(event.delay)
        return seconds < 120 ? "+\(seconds) s" : "+\(seconds / 60) min"
    }
    print("\nPlaces: " + places.map { "\($0.name) (\(Int($0.radius)) m)" }.joined(separator: ", "))
    print("Events:")
    for event in events where DayKey(event.at) == day || DayKey(event.observedAt) == day {
        var text: String
        switch event.kind {
        case .enter: text = "entered \(placeName(.place(event.place!))) (\(event.source?.rawValue ?? "monitor"))"
        case .exit: text = "left \(placeName(.place(event.place!))) (\(event.source?.rawValue ?? "monitor"))"
        case .visit:
            text = "visit until \(event.departure.map(clock) ?? "…")"
            if let latitude = event.latitude, let longitude = event.longitude, let nearest = places.min(by: {
                Place.distance($0.latitude, $0.longitude, latitude, longitude)
                    < Place.distance($1.latitude, $1.longitude, latitude, longitude)
            }) {
                let meters = Place.distance(nearest.latitude, nearest.longitude, latitude, longitude)
                text += String(format: ", %.1f km from %@, ±%.0f m", meters / 1000, nearest.name, event.accuracy ?? 0)
            }
        }
        print("  \(clock(event.at))  \(text)  (\(late(event)))")
    }
    let stays = PlaceStays.build(events, places: places, now: now).filter { $0.end > day.start() && $0.start < day.end() }
    print("Stays:")
    for stay in stays {
        print("  \(clock(stay.start))–\(stay.isOpen ? "now" : clock(stay.end))  \(placeName(stay.whereabouts))")
    }
    print("Use by place:")
    for (whereabouts, apps) in PlaceStays.usage(timeline.blocks, stays: stays)
        .sorted(by: { $0.value.values.reduce(0, +) > $1.value.values.reduce(0, +) }) {
        let top = apps.sorted { $0.value > $1.value }.prefix(4).map { "\(name($0.key)) \(Int(($0.value / 60).rounded()))" }
        print("  \(placeName(whereabouts)): \(Int((apps.values.reduce(0, +) / 60).rounded())) min — " + top.joined(separator: ", "))
    }
}
