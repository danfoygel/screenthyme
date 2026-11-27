import Foundation

/// A threshold crossing on the total ladder: `minute` minutes reached at `at`.
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
    /// Total-use threshold fires: the "in use" strip and live status.
    public var total: [FirePoint]
    /// Apple's per-app usage, as differences between fetches: exact totals and the per-app timeline.
    public var samples: [UsageSample]
    /// When monitoring was (re)registered. iOS then replays today's already-passed total thresholds as a burst.
    public var trackingStarts: [Date]
    /// Websites, whose use Apple also counts as Safari's: left out when weighing how much use a stretch held.
    public var websites: Set<UUID> = []
    /// Browsers and Home Screen web apps (`BuiltInApps.showsWebsites`), whose blocks are matched to a website's use.
    public var browsers: Set<UUID> = []
    /// Items whose use is shown as another's (`ItemAliases`): the call screen's as Phone's.
    public var aliases: [UUID: UUID] = [:]

    public init(dayStart: Date, total: [FirePoint], samples: [UsageSample] = [], trackingStarts: [Date] = []) {
        self.dayStart = dayStart
        self.total = total
        self.samples = samples
        self.trackingStarts = trackingStarts
    }

    /// From synced records (parent side). A total fire at minute 0 marks a tracking start; fires with an item are
    /// leftovers from the old per-app ladders and are ignored.
    public init(fires: [UsageFire], samples: [UsageSample], dayStart: Date) {
        var total: [FirePoint] = []
        var starts: [Date] = []
        for fire in fires where fire.itemID == nil {
            if fire.minute == 0 {
                starts.append(fire.firedAt)
            } else {
                total.append(FirePoint(minute: fire.minute, at: fire.firedAt))
            }
        }
        self.init(dayStart: dayStart, total: total, samples: samples, trackingStarts: starts.sorted())
    }

    /// From the kid's own journal and sample outbox (kid side, debug screen).
    public init(entries: [JournalEntry], samples: [UsageSample], dayStart: Date) {
        var total: [FirePoint] = []
        var starts: [Date] = []
        for entry in entries {
            if entry.isTrackingStart { starts.append(entry.at) }
            guard let parsed = entry.parsedEvent, parsed.itemID == nil else { continue }
            total.append(FirePoint(minute: parsed.minute, at: entry.at))
        }
        self.init(dayStart: dayStart, total: total, samples: samples, trackingStarts: starts)
    }
}

extension JournalEntry {
    /// A registration. Old journals had no explicit marker; the total activity's interval start (named "….total")
    /// stood in for it.
    public var isTrackingStart: Bool {
        kind == .trackingStart || (kind == .intervalStart && activity.hasSuffix(".total"))
    }
}
