import Foundation

/// A threshold crossing on one ladder: `minute` minutes reached at `at`.
public struct FirePoint: Codable, Sendable, Hashable {
    public var minute: Int
    public var at: Date

    public init(minute: Int, at: Date) {
        self.minute = minute
        self.at = at
    }
}

/// Everything the reconstruction needs for one kid on one day.
public struct DayInput: Sendable {
    public var dayStart: Date
    public var total: [FirePoint]
    public var items: [UUID: [FirePoint]]
    public var spec: LadderSpec

    public init(dayStart: Date, total: [FirePoint], items: [UUID: [FirePoint]], spec: LadderSpec = .standard) {
        self.dayStart = dayStart
        self.total = total
        self.items = items
        self.spec = spec
    }

    /// From synced records (parent side).
    public init(fires: [UsageFire], dayStart: Date, spec: LadderSpec = .standard) {
        var total: [FirePoint] = []
        var items: [UUID: [FirePoint]] = [:]
        for fire in fires {
            let point = FirePoint(minute: fire.minute, at: fire.firedAt)
            if let itemID = fire.itemID {
                items[itemID, default: []].append(point)
            } else {
                total.append(point)
            }
        }
        self.init(dayStart: dayStart, total: total, items: items, spec: spec)
    }

    /// From the local journal (kid side, debug screen).
    public init(entries: [JournalEntry], dayStart: Date, spec: LadderSpec = .standard) {
        var total: [FirePoint] = []
        var items: [UUID: [FirePoint]] = [:]
        for entry in entries where entry.kind == .threshold {
            guard let parsed = entry.parsedEvent else { continue }
            let point = FirePoint(minute: parsed.minute, at: entry.at)
            if let itemID = parsed.itemID {
                items[itemID, default: []].append(point)
            } else {
                total.append(point)
            }
        }
        self.init(dayStart: dayStart, total: total, items: items, spec: spec)
    }
}
