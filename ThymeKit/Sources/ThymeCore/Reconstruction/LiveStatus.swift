import Foundation

/// "In use · probably YouTube" / "Idle · last active 8:42pm" (PLAN.md §4.2).
public struct LiveStatus: Sendable, Equatable {
    public var inUse: Bool
    public var probableItem: UUID?
    public var lastActiveAt: Date?

    /// A total fire younger than this means the phone is in use now.
    public static let freshness: TimeInterval = 90

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
        let inUse = age >= -freshness && age <= freshness
        guard inUse, let run = timeline.runs.last else {
            return LiveStatus(inUse: false, probableItem: nil, lastActiveAt: last)
        }
        let runStart = run.start.addingTimeInterval(-Reconstructor.skew)
        var probable: (item: UUID, at: Date)?
        for (item, points) in input.items {
            guard let latest = points.map(\.at).max(), latest >= runStart else { continue }
            if probable == nil || latest > probable!.at {
                probable = (item, latest)
            }
        }
        return LiveStatus(inUse: true, probableItem: probable?.item, lastActiveAt: last)
    }
}
