import Foundation
import ThymeCore

/// Apple's per-hour totals at the `Sampler`'s last fetch (App Group `sampler-snapshot.json`): the Sampler takes
/// differences from it, and the `Enforcer` counts today's use from it. Apart from the Sampler so the shield action
/// extension can enforce without Apple's data.
struct UsageSnapshot: Codable {
    var day: DayKey
    var at: Date
    /// Hour start (seconds since 1970) → item key ("app:<bundle id>" / "web:<domain>") → seconds.
    var hours: [String: [String: Double]]

    static func load() -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: AppGroup.snapshotURL) else { return nil }
        return try? JSONDecoder.thyme.decode(UsageSnapshot.self, from: data)
    }

    func save() {
        try? JSONEncoder.thyme.encode(self).write(to: AppGroup.snapshotURL, options: .atomic)
    }

    /// Apple's seconds today per app and website, as of the last fetch.
    static func todayUsage(kid: Kid, now: Date = Date()) -> [UUID: Double] {
        guard let snapshot = load(), snapshot.day == DayKey(now) else { return [:] }
        var usage: [UUID: Double] = [:]
        for items in snapshot.hours.values {
            for (key, seconds) in items {
                let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let kind: ItemKind = parts[0] == "web" ? .domain : .app
                usage[TrackedItem.id(kid: kid.id, kind: kind, identifier: parts[1]), default: 0] += seconds
            }
        }
        // A scanned app uses what its match in Apple's data uses.
        for item in AppGroup.loadItems() {
            if let match = item.match, let seconds = usage[match] { usage[item.id] = seconds }
        }
        return usage
    }
}
