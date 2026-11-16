import Foundation

/// The total-use thresholds that wake the monitor extension (PLAN.md §13): one every `step` minutes of phone use,
/// `lookahead` registered at a time. Each wake fetches Apple's per-app data. Registering thousands of events made
/// Apple's Screen Time daemon run out of memory on a 4 GB phone (§12), so only a handful are registered at once; the
/// extension re-registers when it gets close to the top.
public struct RollingLadder: Sendable {
    /// Minutes of use between wakes. Precision doesn't depend on it (Apple's numbers are exact); freshness does.
    public var step: Int
    public var lookahead: Int
    /// Highest minute a day can have.
    public static let maxMinute = 1440

    public init(step: Int = 2, lookahead: Int = 10) {
        self.step = step
        self.lookahead = lookahead
    }

    /// The next `lookahead` multiples of `step` above `minute`.
    public func thresholds(after minute: Int) -> [Int] {
        let first = (minute / step + 1) * step
        return Array(stride(from: first, through: Self.maxMinute, by: step).prefix(lookahead))
    }

    /// Probes for a fresh registration: 2, 4, 8, … minutes below `minute`, and `step`. iOS replays the ones its count
    /// has passed, so the highest replay shows where its count is (`LadderCalibration`).
    public func probes(below minute: Int) -> [Int] {
        var probes: Set<Int> = minute > step ? [step] : []
        var depth = step
        while minute - depth > 0 {
            probes.insert(minute - depth)
            depth *= 2
        }
        return probes.sorted()
    }

    /// Re-register once at most half the window remains above the last crossing.
    public func needsRefill(crossed minute: Int, registeredUpTo: Int) -> Bool {
        registeredUpTo - minute <= step * lookahead / 2
    }

    /// Activity names start with the epoch's prefix, so a heartbeat can tell which epoch is still registered.
    public static func prefix(for epochID: UUID) -> String {
        "st.\(epochID.uuidString.prefix(8).lowercased())."
    }

    /// Not ".total": that suffix marked tracking starts in old journals (see `JournalEntry.isTrackingStart`).
    public static func activityName(epochID: UUID) -> String {
        prefix(for: epochID) + "tot"
    }
}
