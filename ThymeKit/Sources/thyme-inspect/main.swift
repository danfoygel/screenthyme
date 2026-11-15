import Foundation
import ThymeCore

// Usage: thyme-inspect <journal-YYYY-MM-DD.jsonl> [config.json]
// Prints the reconstruction for that day in the Mac's time zone, which should match the phone's.

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("usage: thyme-inspect <journal-YYYY-MM-DD.jsonl> [config.json]")
    exit(1)
}
let journalURL = URL(filePath: arguments[1])
let entries = JSONLinesFile<JournalEntry>(url: journalURL).readAll()
let dayString = journalURL.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "journal-", with: "")
guard let day = DayKey(string: dayString) else {
    print("can't read the day from \(journalURL.lastPathComponent)")
    exit(1)
}

struct ConfigItems: Decodable {
    struct Item: Decodable {
        var id: UUID
        var kind: String
        var ordinal: Int
        var nickname: String?
    }

    var items: [Item]
}

let kinds: [UUID: String] = {
    guard arguments.count >= 3, let data = try? Data(contentsOf: URL(filePath: arguments[2])),
          let config = try? JSONDecoder.thyme.decode(ConfigItems.self, from: data) else { return [:] }
    return Dictionary(config.items.map { ($0.id, $0.kind) }, uniquingKeysWith: { a, _ in a })
}()

let names: [UUID: String] = {
    guard arguments.count >= 3, let data = try? Data(contentsOf: URL(filePath: arguments[2])),
          let config = try? JSONDecoder.thyme.decode(ConfigItems.self, from: data) else { return [:] }
    return Dictionary(config.items.map { ($0.id, $0.nickname ?? "\($0.kind) #\($0.ordinal)") }, uniquingKeysWith: { a, _ in a })
}()

@MainActor func name(_ id: UUID) -> String { names[id] ?? String(id.uuidString.prefix(8)) }
func clock(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

let input = DayInput(entries: entries, dayStart: day.start(),
                     shortItems: Set(kinds.filter { $0.value == "domain" }.keys),
                     totalsOnlyItems: Set(kinds.filter { $0.value != "app" }.keys))
let timeline = Reconstructor.build(input)
let thresholds = entries.filter { $0.kind == .threshold }

print("Day \(day): \(entries.count) entries, \(thresholds.count) thresholds (\(input.total.count) total, \(input.items.values.reduce(0) { $0 + $1.count }) item)")
print("Before tracking \(timeline.preTrackingMinutes) min (by item: \(timeline.preTrackingByItem.values.reduce(0, +)))")
print("Total \(timeline.totalMinutes) min · unexplained \(timeline.unexplainedMinutes) · suspect \(timeline.suspectFires) · unfulfilled \(timeline.unfulfilledMinutes)")
print("Runs: " + timeline.runs.map { "\(clock($0.start))–\(clock($0.end))" }.joined(separator: ", "))
print("\nTotals:")
for (id, total) in timeline.totals.sorted(by: { $0.value.lowerMinutes > $1.value.lowerMinutes }) {
    print("  \(name(id).padding(toLength: 14, withPad: " ", startingAt: 0)) \(total.lowerMinutes)–\(total.upperMinutes) min, attributed \(total.attributedMinutes), last crossing \(clock(total.lastCrossingAt))")
}
print("\nSegments:")
for segment in timeline.segments {
    let owner = switch segment.owner {
    case let .item(id): name(id)
    case let .mixed(ids): "mixed(" + ids.map(name).joined(separator: ", ") + ")"
    case .unexplained: "unexplained"
    }
    print("  \(clock(segment.start))–\(clock(segment.end))  \(String(segment.minutes).padding(toLength: 4, withPad: " ", startingAt: 0)) \(segment.confidence)  \(owner)")
}
