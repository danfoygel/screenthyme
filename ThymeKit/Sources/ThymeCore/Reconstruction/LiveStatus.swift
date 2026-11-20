import Foundation

/// "In use · probably YouTube" / "Idle · last active 8:42pm" (PLAN.md §4.2).
public struct LiveStatus: Sendable, Equatable {
    public var inUse: Bool
    public var probableItem: UUID?
    public var lastActiveAt: Date?

    /// A wake (total fire) younger than this means the phone is in use now: one step of a minute plus slack.
    public static let freshness: TimeInterval = 120

    public init(inUse: Bool, probableItem: UUID?, lastActiveAt: Date?) {
        self.inUse = inUse
        self.probableItem = probableItem
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
        // The app with the most use in the latest fetch interval.
        let latestEnd = input.samples.map(\.end).max()
        let latest = input.samples.filter { $0.end == latestEnd && now.timeIntervalSince($0.end) <= freshness }
        let probable = latest.max { $0.seconds < $1.seconds }?.itemID
        return LiveStatus(inUse: true, probableItem: probable, lastActiveAt: last)
    }
}
