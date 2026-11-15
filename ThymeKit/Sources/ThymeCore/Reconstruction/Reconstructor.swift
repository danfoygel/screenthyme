import Foundation

public enum Confidence: Int, Codable, Sendable, Comparable {
    /// Placed by inference: a burst of catch-up fires, a minute far from its crossing, or a ladder tail.
    case low
    /// Another app also crossed a threshold in the same stretch; the minute belongs to one of them.
    case mixed
    /// The app crossed a threshold in this run of use and nothing else did in between.
    case high

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum SegmentOwner: Sendable, Hashable {
    case item(UUID)
    /// Sorted ids of the candidates.
    case mixed([UUID])
    /// In use, but no tracked app's crossings explain it: short uses below 5 min, or apps added since the last scan.
    case unexplained
}

/// One in-use minute from the total ladder.
public struct InUseMinute: Sendable, Hashable {
    public var start: Date
    public var end: Date
    /// Spread out from a burst of fires rather than observed directly.
    public var inferred: Bool
}

public struct Segment: Sendable, Hashable, Identifiable {
    public var owner: SegmentOwner
    public var start: Date
    public var end: Date
    public var minutes: Int
    public var confidence: Confidence

    public var id: Date { start }
}

public struct ItemTotal: Sendable, Hashable {
    /// The last threshold crossed: the app used at least this many minutes.
    public var lowerMinutes: Int
    /// At most this many: the next threshold wasn't reached.
    public var upperMinutes: Int
    /// The last crossing is the top of the item's ladder: at least `lowerMinutes`, with no upper bound.
    public var openEnded: Bool
    public var lastCrossingAt: Date
    /// Minutes the timeline attributes to this item, at any confidence.
    public var attributedMinutes: Int
}

public struct DayTimeline: Sendable {
    public var inUse: [InUseMinute]
    /// Stretches of continuous use (gaps of at most `Reconstructor.runGap`).
    public var runs: [DateInterval]
    public var segments: [Segment]
    public var totals: [UUID: ItemTotal]
    public var totalMinutes: Int
    public var unexplainedMinutes: Int
    /// Fires dropped as impossible or out of order.
    public var suspectFires: Int
    /// Minutes that crossings claim but the total ladder has no room for (likely early fires).
    public var unfulfilledMinutes: Int
    public var lastTotalFireAt: Date?
    /// Use from before monitoring started, replayed by iOS at registration: counted, but its times are unknown.
    public var preTrackingMinutes: Int
    public var preTrackingByItem: [UUID: Int]
}

/// Turns threshold fires into totals and a per-app timeline (PLAN.md §4.2). Pure and deterministic.
public enum Reconstructor {
    /// A pause longer than this ends a run of use (and a session).
    public static let runGap: TimeInterval = 120
    /// Slack for the order in which simultaneous fires from different ladders arrive.
    static let skew: TimeInterval = 5
    /// Fires may run this far ahead of wall-clock time before they count as impossible.
    static let tolerance: TimeInterval = 90

    /// Catch-up fires keep arriving this long after a registration: on a real phone, per-app ones trickled in for 8 min.
    static let catchUpWindow: TimeInterval = 900

    public static func build(_ input: DayInput) -> DayTimeline {
        let total = clean(input.total, dayStart: input.dayStart)
        var suspects = total.suspects
        let (inUse, preTracking) = inUseMinutes(total.points, dayStart: input.dayStart,
                                                trackingStarts: input.trackingStarts)
        let runs = mergeRuns(inUse)

        var demands: [Demand] = []
        var crossings: [(at: Date, item: UUID)] = []
        var lastCrossing: [UUID: FirePoint] = [:]
        for (item, raw) in input.items {
            let series = clean(raw, dayStart: input.dayStart)
            suspects += series.suspects
            if let last = series.points.last { lastCrossing[item] = last }
            guard !input.totalsOnlyItems.contains(item) else { continue }
            demands += makeDemands(item: item, series: series, dayStart: input.dayStart)
            crossings += series.points.map { ($0.at, item) }
        }
        crossings.sort { $0.at < $1.at }

        // Catch-up crossings are paid from the pre-tracking minutes first, so they can't claim today's later use.
        var pool = preTracking
        var preTrackingByItem: [UUID: Int] = [:]
        for index in demands.indices.sorted(by: { demands[$0].crossingAt < demands[$1].crossingAt })
        where pool > 0 && inCatchUp(demands[index].crossingAt, starts: input.trackingStarts) {
            let take = min(pool, demands[index].remaining)
            pool -= take
            demands[index].remaining -= take
            preTrackingByItem[demands[index].item, default: 0] += take
        }

        var owners = assign(minutes: inUse, demands: &demands)
        let unfulfilled = demands.reduce(0) { $0 + $1.remaining }

        // Confidence for assigned minutes.
        var labels: [Label?] = Array(repeating: nil, count: inUse.count)
        for (index, owner) in owners.enumerated() {
            guard let demandIndex = owner else { continue }
            let minute = inUse[index]
            let demand = demands[demandIndex]
            labels[index] = label(minute: minute, demand: demand, runs: runs, crossings: crossings)
        }

        // Ladder tails: minutes right after an item's final crossing, in the same run, up to its remainder.
        var tailUsed: [UUID: Int] = [:]
        for index in inUse.indices where owners[index] == nil {
            let minute = inUse[index]
            guard let run = runs.first(where: { $0.start <= minute.start + skew && minute.end <= $0.end + skew }),
                  let crossing = crossings.last(where: { $0.at <= minute.end + skew && $0.at >= run.start - skew }),
                  let final = lastCrossing[crossing.item], final.at == crossing.at
            else { continue }
            let capacity = input.spec.itemRemainder(after: final.minute,
                                                    short: input.shortItems.contains(crossing.item))
            guard tailUsed[crossing.item, default: 0] < capacity else { continue }
            tailUsed[crossing.item, default: 0] += 1
            labels[index] = Label(owner: .item(crossing.item), confidence: .low)
            owners[index] = -1
        }

        let segments = makeSegments(minutes: inUse, labels: labels)

        var totals: [UUID: ItemTotal] = [:]
        for (item, last) in lastCrossing {
            let attributed = labels.reduce(0) { count, label in
                switch label?.owner {
                case .item(item): count + 1
                case let .mixed(ids) where ids.contains(item): count + 1
                default: count
                }
            }
            let short = input.shortItems.contains(item)
            totals[item] = ItemTotal(lowerMinutes: last.minute,
                                     upperMinutes: last.minute + input.spec.itemRemainder(after: last.minute, short: short),
                                     openEnded: input.spec.nextItemStep(after: last.minute, short: short) == nil,
                                     lastCrossingAt: last.at,
                                     attributedMinutes: attributed)
        }

        return DayTimeline(inUse: inUse,
                           runs: runs,
                           segments: segments,
                           totals: totals,
                           totalMinutes: total.points.last?.minute ?? 0,
                           unexplainedMinutes: labels.filter { $0 == nil }.count,
                           suspectFires: suspects,
                           unfulfilledMinutes: unfulfilled,
                           lastTotalFireAt: total.points.last?.at,
                           preTrackingMinutes: preTracking,
                           preTrackingByItem: preTrackingByItem)
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
            let count = point.minute - previous.minute
            if count > 1, inCatchUp(point.at, starts: trackingStarts) {
                preTracking += count
                previous = point
                continue
            }
            let width = min(60, point.at.timeIntervalSince(previous.at) / Double(count))
            for offset in 0..<count {
                let end = point.at.addingTimeInterval(-Double(offset) * width)
                minutes.append(InUseMinute(start: end.addingTimeInterval(-width), end: end, inferred: count > 1))
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

    // MARK: - Attribution

    /// "Item used `remaining` in-use minutes between `windowStart` and `crossingAt`."
    struct Demand {
        var item: UUID
        var windowStart: Date
        var crossingAt: Date
        var remaining: Int
        var burst: Bool
    }

    static func makeDemands(item: UUID, series: Series, dayStart: Date) -> [Demand] {
        var demands: [Demand] = []
        var previous = FirePoint(minute: 0, at: dayStart)
        for (index, point) in series.points.enumerated() {
            let minutes = point.minute - previous.minute
            if series.bursts.contains(index), var last = demands.popLast() {
                // Catch-up: fold into the previous window rather than demanding minutes in zero time.
                last.crossingAt = point.at
                last.remaining += minutes
                last.burst = true
                demands.append(last)
            } else {
                demands.append(Demand(item: item, windowStart: previous.at, crossingAt: point.at,
                                      remaining: minutes, burst: series.bursts.contains(index)))
            }
            previous = point
        }
        return demands
    }

    /// Latest minutes first; each goes to the eligible demand whose window starts latest. This places usage as close
    /// before each crossing as possible: the app was in the foreground at the moment it crossed.
    /// Returns, per minute, the index of the demand it went to.
    static func assign(minutes: [InUseMinute], demands: inout [Demand]) -> [Int?] {
        var owners: [Int?] = Array(repeating: nil, count: minutes.count)
        let byCrossing = demands.indices.sorted { demands[$0].crossingAt > demands[$1].crossingAt }
        var next = 0
        var active: [Int] = []
        for index in minutes.indices.reversed() {
            let minute = minutes[index]
            while next < byCrossing.count, demands[byCrossing[next]].crossingAt - skew > minute.start {
                active.append(byCrossing[next])
                next += 1
            }
            active.removeAll { demands[$0].remaining == 0 || demands[$0].windowStart >= minute.end - skew }
            guard let pick = active.max(by: { a, b in
                let lhs = demands[a], rhs = demands[b]
                if lhs.windowStart != rhs.windowStart { return lhs.windowStart < rhs.windowStart }
                return lhs.crossingAt > rhs.crossingAt
            }) else { continue }
            demands[pick].remaining -= 1
            owners[index] = pick
        }
        return owners
    }

    struct Label: Equatable {
        var owner: SegmentOwner
        var confidence: Confidence
    }

    static func label(minute: InUseMinute, demand: Demand, runs: [DateInterval],
                      crossings: [(at: Date, item: UUID)]) -> Label {
        let own = Label(owner: .item(demand.item), confidence: .low)
        if minute.inferred || demand.burst { return own }
        let run = runs.first { $0.start <= minute.start + skew && minute.end <= $0.end + skew }
        guard let run, demand.crossingAt >= run.start - skew, demand.crossingAt <= run.end + skew else { return own }
        let others = Set(crossings
            .filter { $0.item != demand.item && $0.at > minute.start + skew && $0.at < demand.crossingAt - skew }
            .map(\.item))
        if others.isEmpty {
            return Label(owner: .item(demand.item), confidence: .high)
        }
        let ids = (others.union([demand.item])).sorted { $0.uuidString < $1.uuidString }
        return Label(owner: .mixed(ids), confidence: .mixed)
    }

    static func makeSegments(minutes: [InUseMinute], labels: [Label?]) -> [Segment] {
        var segments: [Segment] = []
        for (minute, label) in zip(minutes, labels) {
            let owner = label?.owner ?? .unexplained
            let confidence = label?.confidence ?? .low
            if var last = segments.last, last.owner == owner, last.confidence == confidence,
               minute.start.timeIntervalSince(last.end) <= runGap {
                last.end = max(last.end, minute.end)
                last.minutes += 1
                segments[segments.count - 1] = last
            } else {
                segments.append(Segment(owner: owner, start: minute.start, end: minute.end, minutes: 1,
                                        confidence: confidence))
            }
        }
        return segments
    }
}
