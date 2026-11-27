import Foundation

/// Where the phone was.
public enum Whereabouts: Hashable, Sendable {
    case place(UUID)
    /// A visit outside every place's fence: "Other locations" on parents' phones.
    case elsewhere
    /// No fence or visit covers the time: on the move, or iOS didn't say ("While moving").
    case unknown
}

/// A stretch of time at one place. Stays never overlap.
public struct PlaceStay: Sendable, Hashable {
    public var whereabouts: Whereabouts
    public var start: Date
    public var end: Date
    /// Still there when the stays were built: `end` is "now".
    public var isOpen: Bool
}

/// Geofence crossings and visits → where the phone was, and each app's use split by place. Pure.
public enum PlaceStays {
    /// The same visit, reported again with its departure, arrives within this of the first report.
    static let sameVisit: TimeInterval = 60

    /// Stays from the events, up to `now`. A fence's stay wins over a visit; between two fences, the later entry.
    /// A visit inside a place's fence counts as that place, in case its own crossing was missed, and a visit outside
    /// it ends the fence's stay, in case the exit was missed: iOS once reported none all day (PLAN.md §19).
    public static func build(_ events: [PlaceEvent], places: [Place], now: Date) -> [PlaceStay] {
        struct Raw {
            var whereabouts: Whereabouts
            var start: Date
            var end: Date
            var isOpen: Bool
            var rank: Int
        }
        var raws: [Raw] = []
        var entered: [UUID: Date] = [:]
        let known = Set(places.map(\.id))
        for event in events.sorted(by: { $0.at < $1.at }) where event.at <= now {
            // A fence's events count only while it's one of `places`: not once removed, nor another phone's test fences.
            guard let place = event.place, known.contains(place) else { continue }
            switch event.kind {
            case .enter:
                if entered[place] == nil { entered[place] = event.at }
            case .exit:
                if let start = entered.removeValue(forKey: place), event.at > start {
                    raws.append(Raw(whereabouts: .place(place), start: start, end: event.at, isOpen: false, rank: 2))
                }
            case .visit:
                break
            }
        }
        for (place, start) in entered where now > start {
            raws.append(Raw(whereabouts: .place(place), start: start, end: now, isOpen: true, rank: 2))
        }
        let visits = visits(events)
        // The phone left by the first visit outside the fence: when it left the fence's last visit, if one says so.
        for index in raws.indices {
            guard case let .place(id) = raws[index].whereabouts, let place = places.first(where: { $0.id == id }) else {
                continue
            }
            let stay = raws[index]
            guard let away = visits.first(where: { $0.at > stay.start && $0.at < stay.end && $0.isInside(place) == false })
            else { continue }
            let left = visits.compactMap { visit -> Date? in
                guard visit.isInside(place) == true, let departure = visit.departure,
                      departure > stay.start, departure <= away.at else { return nil }
                return departure
            }.max()
            raws[index].end = left ?? away.at
            raws[index].isOpen = false
        }
        for visit in visits where visit.at < now {
            let end = min(visit.departure ?? now, now)
            guard end > visit.at else { continue }
            let whereabouts = VisitClusters.place(of: visit, in: places).map { Whereabouts.place($0.id) } ?? .elsewhere
            raws.append(Raw(whereabouts: whereabouts, start: visit.at, end: end,
                            isOpen: visit.departure.map { $0 > now } ?? true, rank: 1))
        }

        // Flatten: each piece between two boundaries goes to its best-ranked, latest-started stay.
        let boundaries = Set(raws.flatMap { [$0.start, $0.end] }).sorted()
        var stays: [PlaceStay] = []
        for (from, to) in zip(boundaries, boundaries.dropFirst()) {
            let covering = raws.filter { $0.start <= from && $0.end >= to }
            guard let best = covering.max(by: { ($0.rank, $0.start) < ($1.rank, $1.start) }) else { continue }
            let isOpen = best.isOpen && to == best.end
            if var last = stays.last, last.whereabouts == best.whereabouts, last.end == from {
                last.end = to
                last.isOpen = isOpen
                stays[stays.count - 1] = last
            } else {
                stays.append(PlaceStay(whereabouts: best.whereabouts, start: from, end: to, isOpen: isOpen))
            }
        }
        return stays
    }

    /// One event per visit: a report with the departure replaces the arrival-only one. Each phone's apart.
    public static func visits(_ events: [PlaceEvent]) -> [PlaceEvent] {
        var visits: [PlaceEvent] = []
        for event in events.sorted(by: { $0.at < $1.at }) where event.kind == .visit {
            if let index = visits.lastIndex(where: {
                $0.kidID == event.kidID && abs($0.at.timeIntervalSince(event.at)) <= sameVisit
            }) {
                if visits[index].departure == nil { visits[index] = event }
            } else {
                visits.append(event)
            }
        }
        return visits
    }

    /// The stays' parts within `interval` (a day).
    public static func clip(_ stays: [PlaceStay], to interval: DateInterval) -> [PlaceStay] {
        stays.compactMap { stay in
            let start = max(stay.start, interval.start), end = min(stay.end, interval.end)
            guard end > start else { return nil }
            return PlaceStay(whereabouts: stay.whereabouts, start: start, end: end, isOpen: stay.isOpen && end == stay.end)
        }
    }

    /// Each app's seconds by where the phone was, a block's seconds shared out by how much of it each stay covers. A
    /// browser's time on websites is theirs (`UsageBlock.ownSeconds`).
    public static func usage(_ blocks: [UsageBlock], stays: [PlaceStay]) -> [Whereabouts: [UUID: Double]] {
        var result: [Whereabouts: [UUID: Double]] = [:]
        for block in blocks where block.ownSeconds > 0 {
            let length = block.end.timeIntervalSince(block.start)
            var placed = 0.0
            for stay in stays {
                let share: Double
                if length > 0 {
                    share = max(0, min(block.end, stay.end).timeIntervalSince(max(block.start, stay.start))) / length
                } else {
                    share = stay.start <= block.start && block.start < stay.end ? 1 : 0
                }
                guard share > 0 else { continue }
                result[stay.whereabouts, default: [:]][block.itemID, default: 0] += block.ownSeconds * share
                placed += share
            }
            if placed < 0.999 {
                result[.unknown, default: [:]][block.itemID, default: 0] += block.ownSeconds * (1 - placed)
            }
        }
        return result
    }
}

extension PlaceEvent {
    /// Whether a visit was inside the place's fence, allowing for its accuracy; nil without coordinates.
    func isInside(_ place: Place) -> Bool? {
        guard let latitude, let longitude else { return nil }
        return place.contains(latitude: latitude, longitude: longitude, accuracy: accuracy ?? 0)
    }
}

/// One kid's day by location, on parents' phones (PLAN.md §19): where the phone stayed, and each app's use at each of
/// the family's places, at other locations (visits no place covers) and while moving (outside every visit).
public struct LocationDay: Sendable {
    /// Days of events before the day that count: a fence entered or a visit begun then can still be open.
    public static let lookbackDays = 7

    /// Within the day.
    public var stays: [PlaceStay]
    public var usage: [Whereabouts: [UUID: Double]]

    /// - Parameter events: the kid's, from `lookbackDays` before the day through the day.
    public init(events: [PlaceEvent], places: [Place], blocks: [UsageBlock], day: DateInterval, now: Date) {
        let stays = PlaceStays.build(events, places: places, now: min(now, day.end))
        self.stays = PlaceStays.clip(stays, to: day)
        usage = PlaceStays.usage(blocks, stays: self.stays)
    }

    public func seconds(at whereabouts: Whereabouts, items: Set<UUID>? = nil) -> Double {
        (usage[whereabouts] ?? [:]).filter { items?.contains($0.key) ?? true }.values.reduce(0, +)
    }

    /// Where there was use, the family's places by time first, then other locations, then while moving.
    public func locations(items: Set<UUID>? = nil) -> [(whereabouts: Whereabouts, seconds: Double)] {
        Self.locations([self], items: items)
    }

    /// Several days' use by location, in the same order.
    public static func locations(_ days: [LocationDay], items: Set<UUID>? = nil)
        -> [(whereabouts: Whereabouts, seconds: Double)] {
        var seconds: [Whereabouts: Double] = [:]
        for day in days {
            for whereabouts in day.usage.keys { seconds[whereabouts, default: 0] += day.seconds(at: whereabouts, items: items) }
        }
        return seconds.map { ($0.key, $0.value) }
            .filter { $0.1 >= 1 }
            .sorted { a, b in (rank(a.0), -a.1) < (rank(b.0), -b.1) }
    }

    private static func rank(_ whereabouts: Whereabouts) -> Int {
        switch whereabouts {
        case .place: 0
        case .elsewhere: 1
        case .unknown: 2
        }
    }
}
