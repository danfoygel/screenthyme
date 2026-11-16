import Foundation

/// How iOS's count of today's use relates to ours (PLAN.md §16). A new authorization grant can make iOS count today
/// lower than before, by tens of minutes, so a ladder registered above our total was that much use from its next
/// wake. A fresh registration adds probes below our total (`RollingLadder.probes`); iOS replays those it
/// has passed, and the highest replay sets `offset`. Ladder events are then in iOS's minutes, and each fire is
/// `offset` more in ours.
public struct LadderCalibration: Codable, Sendable, Hashable {
    /// Our total when the alarm was registered (`MonitorDayState.totalMinute`).
    public var base: Int
    /// Our minutes minus iOS's.
    public var offset = 0
    /// Highest of iOS's minutes known passed, from replays.
    public var floor: Int?
    /// Replays arrive within seconds of a registration; probe fires after this are ignored, and ladder fires are use.
    public var replaysUntil: Date?

    /// Long enough for a registration's replays (sometimes only ~2 per second).
    public static let replayWindow: TimeInterval = 60

    public init(base: Int, registeredAt: Date) {
        self.base = base
        replaysUntil = registeredAt.addingTimeInterval(Self.replayWindow)
    }

    func replaying(at date: Date) -> Bool {
        replaysUntil.map { date < $0 } ?? false
    }

    /// A probe fired: iOS's count has passed `minute`. False when it's too late to be a replay.
    public mutating func probePassed(_ minute: Int, at date: Date) -> Bool {
        guard replaying(at: date) else { return false }
        floor = max(floor ?? minute, minute)
        return true
    }

    /// Once the probes' replays are in: the iOS minute to register the ladder after, if the offset changed.
    public mutating func settle(at date: Date, step: Int) -> Int? {
        guard let floor else { return nil }
        // The top probe passed: iOS's count is where ours is.
        let settled = floor >= base - step ? 0 : base - floor
        guard settled != offset else { return nil }
        offset = settled
        replaysUntil = date.addingTimeInterval(Self.replayWindow)
        return offset == 0 ? base : floor
    }

    /// A ladder event fired at iOS's `minute`: our minute for a fire of use, or nil for a replay that refines the
    /// offset. Before any offset, replays are use, as at every registration (the reconstruction's catch-up).
    public mutating func ladderFired(_ minute: Int, at date: Date) -> Int? {
        guard offset > 0, replaying(at: date) else { return minute + offset }
        floor = max(floor ?? minute, minute)
        offset = max(0, base - floor!)
        return nil
    }
}
