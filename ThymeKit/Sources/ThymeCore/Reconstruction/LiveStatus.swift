import Foundation

/// "In use · probably YouTube for 25 min" / "Idle · last active 8:42pm" (PLAN.md §4.2).
public struct LiveStatus: Sendable, Equatable {
    public var inUse: Bool
    public var probableItem: UUID?
    /// When the probable item took over: the start of the fetches in a row that it led, within this run of use.
    public var probableSince: Date?
    public var lastActiveAt: Date?

    /// A wake (total fire) younger than this means the phone is in use now: one step of a minute plus slack.
    public static let freshness: TimeInterval = 120

    public init(inUse: Bool, probableItem: UUID?, probableSince: Date? = nil, lastActiveAt: Date?) {
        self.inUse = inUse
        self.probableItem = probableItem
        self.probableSince = probableSince
        self.lastActiveAt = lastActiveAt
    }

    public static func compute(_ timeline: DayTimeline, input: DayInput, now: Date) -> LiveStatus {
        guard let last = timeline.lastTotalFireAt else {
            return LiveStatus(inUse: false, probableItem: nil, lastActiveAt: nil)
        }
        // Fires stamped well after `now` (clock skew, replayed test data) don't mean "in use now".
        let age = now.timeIntervalSince(last)
        guard age >= -freshness, age <= freshness else {
            return LiveStatus(inUse: false, probableItem: nil, lastActiveAt: last)
        }
        // Each fetch's use, latest first. The app with the most use in the latest one is the probable app.
        let fetches = Dictionary(grouping: input.samples, by: \.end).sorted { $0.key > $1.key }
        func top(_ samples: [UsageSample]) -> UUID? { samples.max { $0.seconds < $1.seconds }?.itemID }
        guard let latest = fetches.first, now.timeIntervalSince(latest.key) <= freshness,
              let probable = top(latest.value) else {
            return LiveStatus(inUse: true, probableItem: nil, lastActiveAt: last)
        }
        // A fetch's start can reach back to the previous one, before an idle stretch: no earlier than this run.
        let runStart = timeline.runs.last?.start
        var since = latest.value.map(\.start).min()!
        for (end, samples) in fetches {
            if let runStart, end <= runStart { break }
            guard top(samples) == probable else { break }
            since = min(since, samples.map(\.start).min()!)
        }
        if let runStart { since = max(since, runStart) }
        return LiveStatus(inUse: true, probableItem: probable, probableSince: since, lastActiveAt: last)
    }
}
