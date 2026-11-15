import Foundation

/// One in-use minute from the total ladder.
public struct InUseMinute: Sendable, Hashable {
    public var start: Date
    public var end: Date
    /// Spread out from a burst of fires rather than observed directly.
    public var inferred: Bool
}

/// An app's usage today, from Apple's numbers.
public struct ItemUsage: Sendable, Hashable {
    public var seconds: Double
    public var firstAt: Date
    public var lastAt: Date

    public var minutes: Int { Int((seconds / 60).rounded()) }
}

/// A stretch on an item's timeline lane: `seconds` of use somewhere between `start` and `end`.
public struct UsageBlock: Sendable, Hashable, Identifiable {
    public var itemID: UUID
    public var start: Date
    public var end: Date
    public var seconds: Double

    public var id: String { "\(itemID)-\(start.timeIntervalSince1970)" }
    /// The share of the stretch the item was in use: 1 when it filled it.
    public var intensity: Double {
        min(1, seconds / max(end.timeIntervalSince(start), 1))
    }
}

public struct DayTimeline: Sendable {
    public var inUse: [InUseMinute]
    /// Stretches of continuous use (gaps of at most `Reconstructor.runGap`).
    public var runs: [DateInterval]
    public var blocks: [UsageBlock]
    public var items: [UUID: ItemUsage]
    /// From the total ladder.
    public var totalMinutes: Int
    /// Total-ladder minutes replayed at a registration: counted, but their times are unknown.
    public var preTrackingMinutes: Int
    /// Fires dropped as impossible.
    public var suspectFires: Int
    public var lastTotalFireAt: Date?

    /// Apple's total over apps and websites (websites also count toward Safari, so this can double count).
    public var appMinutes: Int {
        Int((items.values.reduce(0) { $0 + $1.seconds } / 60).rounded())
    }
}

/// Builds a day from total fires (when the phone was in use) and Apple's per-app samples (what was used, exactly).
/// Pure and deterministic.
public enum Reconstructor {
    /// A pause longer than this ends a run of use.
    public static let runGap: TimeInterval = 120
    /// Fires may run this far ahead of wall-clock time before they count as impossible.
    static let tolerance: TimeInterval = 90
    /// Catch-up fires keep arriving this long after a registration.
    static let catchUpWindow: TimeInterval = 900
    /// Samples this close together are one stretch on a lane.
    static let blockGap: TimeInterval = 5

    public static func build(_ input: DayInput) -> DayTimeline {
        let total = clean(input.total, dayStart: input.dayStart)
        let (inUse, preTracking) = inUseMinutes(total.points, dayStart: input.dayStart,
                                                trackingStarts: input.trackingStarts)
        var items: [UUID: ItemUsage] = [:]
        for sample in input.samples where sample.seconds > 0 {
            var usage = items[sample.itemID] ?? ItemUsage(seconds: 0, firstAt: sample.start, lastAt: sample.end)
            usage.seconds += sample.seconds
            usage.firstAt = min(usage.firstAt, sample.start)
            usage.lastAt = max(usage.lastAt, sample.end)
            items[sample.itemID] = usage
        }
        return DayTimeline(inUse: inUse,
                           runs: mergeRuns(inUse),
                           blocks: blocks(input.samples),
                           items: items,
                           totalMinutes: total.points.last?.minute ?? 0,
                           preTrackingMinutes: preTracking,
                           suspectFires: total.suspects,
                           lastTotalFireAt: total.points.last?.at)
    }

    /// Each item's samples, with back-to-back ones merged into one stretch.
    static func blocks(_ samples: [UsageSample]) -> [UsageBlock] {
        var blocks: [UsageBlock] = []
        let byItem = Dictionary(grouping: samples.filter { $0.seconds > 0 }, by: \.itemID)
        for (item, itemSamples) in byItem {
            var current: UsageBlock?
            for sample in itemSamples.sorted(by: { $0.start < $1.start }) {
                if var block = current, sample.start.timeIntervalSince(block.end) <= blockGap {
                    block.end = max(block.end, sample.end)
                    block.seconds += sample.seconds
                    current = block
                } else {
                    if let current { blocks.append(current) }
                    current = UsageBlock(itemID: item, start: sample.start, end: sample.end, seconds: sample.seconds)
                }
            }
            if let current { blocks.append(current) }
        }
        return blocks.sorted { $0.start < $1.start }
    }

    static func inCatchUp(_ date: Date, starts: [Date]) -> Bool {
        starts.contains { date >= $0 && date.timeIntervalSince($0) <= catchUpWindow }
    }

    // MARK: - Cleaning

    struct Series {
        var points: [FirePoint]
        var suspects: Int
        /// Indices into `points` that arrived faster than wall-clock time allows (catch-up or misfire).
        var bursts: Set<Int>
    }

    /// Fires closer together than this are one delivery. iOS delivers catch-up fires (after a registration) in
    /// random order, sometimes throttled to ~2 per second.
    static let burstGap: TimeInterval = 2

    static func clean(_ raw: [FirePoint], dayStart: Date) -> Series {
        let sorted = orderBursts(raw)
        var points: [FirePoint] = []
        var suspects = 0
        var bursts = Set<Int>()
        var lastMinute = 0
        var lastAt = dayStart
        for point in sorted {
            // Already seen: a duplicate, or a catch-up replay after re-registration.
            if point.minute <= lastMinute { continue }
            if Double(point.minute) * 60 > point.at.timeIntervalSince(dayStart) + tolerance {
                suspects += 1
                continue
            }
            if Double(point.minute - lastMinute) * 60 > point.at.timeIntervalSince(lastAt) + tolerance {
                bursts.insert(points.count)
            }
            points.append(point)
            lastMinute = point.minute
            lastAt = point.at
        }
        return Series(points: points, suspects: suspects, bursts: bursts)
    }

    /// Sorts by time, then gives every fire in a burst the burst's last time and sorts the burst by minute.
    static func orderBursts(_ raw: [FirePoint]) -> [FirePoint] {
        let byTime = raw.sorted { ($0.at, $0.minute) < ($1.at, $1.minute) }
        var result: [FirePoint] = []
        var burst: [FirePoint] = []
        func close() {
            guard let end = burst.last?.at else { return }
            result += burst.map { FirePoint(minute: $0.minute, at: end) }.sorted { $0.minute < $1.minute }
            burst = []
        }
        for point in byTime {
            if let last = burst.last, point.at.timeIntervalSince(last.at) >= burstGap { close() }
            burst.append(point)
        }
        close()
        return result
    }

    // MARK: - In-use minutes

    /// Total fires closer together than this are one delivery (a catch-up), not separate minutes.
    static let coalesce: TimeInterval = 30

    /// Each total fire ends one in-use minute. A jump of n minutes is spread back from the fire, squeezed if needed,
    /// unless it's a registration's catch-up: those minutes happened before tracking and are only counted.
    static func inUseMinutes(_ points: [FirePoint], dayStart: Date,
                             trackingStarts: [Date] = []) -> (minutes: [InUseMinute], preTracking: Int) {
        var deliveries: [FirePoint] = []
        for point in points {
            if let last = deliveries.last, point.at.timeIntervalSince(last.at) < coalesce {
                deliveries[deliveries.count - 1] = point
            } else {
                deliveries.append(point)
            }
        }
        var minutes: [InUseMinute] = []
        var preTracking = 0
        var previous = FirePoint(minute: 0, at: dayStart)
        for point in deliveries {
            var count = point.minute - previous.minute
            // A registration's catch-up: more minutes than have passed since tracking started. Only the excess is
            // before tracking; minutes that fit in the elapsed time are real use.
            if count > 1, let start = trackingStarts.last(where: { $0 <= point.at }), inCatchUp(point.at, starts: [start]) {
                let elapsed = point.at.timeIntervalSince(max(previous.at, start))
                let excess = count - Int((elapsed / 60).rounded())
                if excess > 0 {
                    preTracking += excess
                    count -= excess
                }
            }
            guard count > 0 else {
                previous = point
                continue
            }
            let span = point.at.timeIntervalSince(previous.at)
            let width = min(60, span / Double(count))
            // Several minutes per wake is normal (one wake per `RollingLadder.step`); faster than real time isn't.
            let inferred = Double(count) * 60 > span + tolerance
            for offset in 0..<count {
                let end = point.at.addingTimeInterval(-Double(offset) * width)
                minutes.append(InUseMinute(start: end.addingTimeInterval(-width), end: end, inferred: inferred))
            }
            previous = point
        }
        return (minutes.sorted { $0.start < $1.start }, preTracking)
    }

    static func mergeRuns(_ minutes: [InUseMinute]) -> [DateInterval] {
        var runs: [DateInterval] = []
        for minute in minutes {
            if let last = runs.last, minute.start.timeIntervalSince(last.end) <= runGap {
                runs[runs.count - 1] = DateInterval(start: last.start, end: max(last.end, minute.end))
            } else {
                runs.append(DateInterval(start: minute.start, end: minute.end))
            }
        }
        return runs
    }

}
