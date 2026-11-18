import Foundation

/// The calendar's time axis, top to bottom: the day at `scale` points per hour, except that long stretches with
/// nothing to show are cut out, each drawn as a short break in the tape. Pure and deterministic.
public struct CalendarAxis: Sendable, Hashable {
    public struct Segment: Sendable, Hashable {
        public var interval: DateInterval
        /// Cut out: drawn `CalendarAxis.breakHeight` tall, however long it is.
        public var isBreak: Bool
        /// Points from the top of the axis.
        public var top: Double
        public var height: Double
    }

    public static let breakHeight: Double = 28
    /// Break edges fall on these (from the start of the day), so they read as round times.
    static let rounding: TimeInterval = 300
    /// The tick steps the axis picks from, finest first.
    static let tickSteps: [TimeInterval] = [300, 600, 900, 1800, 3600]

    public let day: DateInterval
    /// Points per hour outside the breaks.
    public let scale: Double
    public let segments: [Segment]

    public var height: Double { segments.last.map { $0.top + $0.height } ?? 0 }

    /// `keep` is what has to be shown (the blocks drawn, the current time). Time farther than a margin from any of it
    /// is cut out where that saves enough: the margin and the shortest cut are in points, so zooming in cuts more.
    /// With nothing to keep, nothing is cut.
    public init(day: DateInterval, scale: Double, keep: [DateInterval]) {
        self.day = day
        self.scale = scale
        let seconds = 3600 / scale
        let margin = min(max(30 * seconds, 300), 900)
        let shortest = max(100 * seconds, 1200)

        // What's kept, with its margins, clipped to the day and merged.
        var shown: [DateInterval] = []
        for kept in keep.sorted(by: { $0.start < $1.start }) {
            let start = max(day.start, kept.start.addingTimeInterval(-margin))
            let end = min(day.end, kept.end.addingTimeInterval(margin))
            guard start <= end else { continue }
            if let last = shown.last, start <= last.end {
                shown[shown.count - 1].end = max(last.end, end)
            } else {
                shown.append(DateInterval(start: start, end: end))
            }
        }
        var cuts: [DateInterval] = []
        if !shown.isEmpty {
            var cursor = day.start
            for next in shown + [DateInterval(start: day.end, duration: 0)] {
                // Rounded inward, so the margins only grow; the day's own edges stay put.
                let start = cursor == day.start ? cursor : Self.round(cursor, in: day, up: true)
                let end = next.start == day.end ? day.end : Self.round(next.start, in: day, up: false)
                if end.timeIntervalSince(start) >= shortest { cuts.append(DateInterval(start: start, end: end)) }
                cursor = max(cursor, next.end)
            }
        }

        var segments: [Segment] = []
        var top = 0.0, cursor = day.start
        func add(_ interval: DateInterval, isBreak: Bool) {
            guard interval.duration > 0 else { return }
            let height = isBreak ? Self.breakHeight : interval.duration / 3600 * scale
            segments.append(Segment(interval: interval, isBreak: isBreak, top: top, height: height))
            top += height
        }
        for cut in cuts {
            add(DateInterval(start: cursor, end: cut.start), isBreak: false)
            add(cut, isBreak: true)
            cursor = cut.end
        }
        add(DateInterval(start: cursor, end: max(cursor, day.end)), isBreak: false)
        self.segments = segments
    }

    private static func round(_ date: Date, in day: DateInterval, up: Bool) -> Date {
        let steps = date.timeIntervalSince(day.start) / rounding
        return day.start.addingTimeInterval((up ? steps.rounded(.up) : steps.rounded(.down)) * rounding)
    }

    public var breaks: [Segment] { segments.filter(\.isBreak) }

    /// Points from the top. A time inside a break lands on the break in proportion.
    public func y(_ date: Date) -> Double {
        guard let segment = segments.last(where: { $0.interval.start <= date }) ?? segments.first else { return 0 }
        let fraction = min(max(date.timeIntervalSince(segment.interval.start) / segment.interval.duration, 0), 1)
        return segment.top + fraction * segment.height
    }

    /// The time at `y` points from the top: the inverse of `y(_:)`.
    public func date(at y: Double) -> Date {
        guard let segment = segments.last(where: { $0.top <= y }) ?? segments.first else { return day.start }
        let fraction = min(max((y - segment.top) / segment.height, 0), 1)
        return segment.interval.start.addingTimeInterval(fraction * segment.interval.duration)
    }

    /// Times to label beside the axis: whole multiples of the finest step that leaves `spacing` points between
    /// labels, outside the breaks and at least `clearance` points from their edges.
    public func ticks(spacing: Double, clearance: Double = 8) -> [Date] {
        let step = Self.tickSteps.first { $0 / 3600 * scale >= spacing } ?? Self.tickSteps.last!
        return stride(from: 0, through: day.duration, by: step).compactMap { offset -> Date? in
            let date = day.start.addingTimeInterval(offset)
            let y = y(date)
            let crowded = breaks.contains { y > $0.top - clearance && y < $0.top + $0.height + clearance }
            return crowded ? nil : date
        }
    }
}
