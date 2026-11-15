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
    /// Items on the short (website) ladder.
    public var shortItems: Set<UUID>
    /// Items whose time overlaps other items' (categories; websites, which also count as Safari): they get totals
    /// but don't take minutes on the timeline.
    public var totalsOnlyItems: Set<UUID>
    /// When monitoring was (re)registered. iOS then replays today's already-passed thresholds as a catch-up burst.
    public var trackingStarts: [Date]

    public init(dayStart: Date, total: [FirePoint], items: [UUID: [FirePoint]], spec: LadderSpec = .standard,
                shortItems: Set<UUID> = [], totalsOnlyItems: Set<UUID> = [], trackingStarts: [Date] = []) {
        self.dayStart = dayStart
        self.total = total
        self.items = items
        self.spec = spec
        self.shortItems = shortItems
        self.totalsOnlyItems = totalsOnlyItems
        self.trackingStarts = trackingStarts
    }

    /// From synced records (parent side). A total fire at minute 0 marks a tracking start.
    public init(fires: [UsageFire], dayStart: Date, spec: LadderSpec = .standard, shortItems: Set<UUID> = [],
                totalsOnlyItems: Set<UUID> = []) {
        var total: [FirePoint] = []
        var items: [UUID: [FirePoint]] = [:]
        var starts: [Date] = []
        for fire in fires {
            let point = FirePoint(minute: fire.minute, at: fire.firedAt)
            if let itemID = fire.itemID {
                items[itemID, default: []].append(point)
            } else if fire.minute == 0 {
                starts.append(fire.firedAt)
            } else {
                total.append(point)
            }
        }
        self.init(dayStart: dayStart, total: total, items: items, spec: spec, shortItems: shortItems,
                  totalsOnlyItems: totalsOnlyItems, trackingStarts: starts.sorted())
    }

    /// From the local journal (kid side, debug screen).
    public init(entries: [JournalEntry], dayStart: Date, spec: LadderSpec = .standard, shortItems: Set<UUID> = [],
                totalsOnlyItems: Set<UUID> = []) {
        var total: [FirePoint] = []
        var items: [UUID: [FirePoint]] = [:]
        var starts: [Date] = []
        for entry in entries {
            if entry.isTrackingStart { starts.append(entry.at) }
            guard entry.kind == .threshold, let parsed = entry.parsedEvent else { continue }
            let point = FirePoint(minute: parsed.minute, at: entry.at)
            if let itemID = parsed.itemID {
                items[itemID, default: []].append(point)
            } else {
                total.append(point)
            }
        }
        self.init(dayStart: dayStart, total: total, items: items, spec: spec, shortItems: shortItems,
                  totalsOnlyItems: totalsOnlyItems, trackingStarts: starts)
    }
}

extension JournalEntry {
    /// The total ladder's interval started: a registration (or midnight).
    public var isTrackingStart: Bool {
        kind == .intervalStart && activity.hasSuffix(".total")
    }
}
