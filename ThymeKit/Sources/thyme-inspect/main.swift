import Foundation
import ThymeCore

// Usage: thyme-inspect <journal-YYYY-MM-DD.jsonl> [samples.jsonl] [items.json]
// Files as copied off a kid phone (App Group Library/ScreenThyme: Journal/, Outbox/samples.jsonl, items.json).
// Prints the day in the Mac's time zone, which should match the phone's.

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("usage: thyme-inspect <journal-YYYY-MM-DD.jsonl> [samples.jsonl] [items.json]")
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
