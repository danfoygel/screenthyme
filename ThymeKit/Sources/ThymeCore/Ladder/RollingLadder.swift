import Foundation

/// Which thresholds to register right now (PLAN.md §4.1, §11): each item's next few ladder steps and the total's
/// next minutes. Registering whole ladders up front (thousands of events) made Apple's Screen Time daemon run out
/// of memory on a 4 GB phone; rolling keeps a few hundred registered at a time. The extension re-registers an
/// activity after each crossing in it.
public struct RollingLadder: Sendable {
    public static let maxItemActivities = 19  // plus one for the total; Apple allows 20

    public var spec: LadderSpec
    public var itemLookahead: Int
    public var totalLookahead: Int
    /// Re-register the total once fewer than this many registered minutes remain above the last crossing.
    public var totalRefill: Int

    public init(spec: LadderSpec = .standard, itemLookahead: Int = 2, totalLookahead: Int = 20, totalRefill: Int = 10) {
        self.spec = spec
        self.itemLookahead = itemLookahead
        self.totalLookahead = totalLookahead
        self.totalRefill = totalRefill
    }

    /// The item's next thresholds after its last crossing `minute` (0 if none today).
    public func itemThresholds(after minute: Int, short: Bool) -> [Int] {
        Array(spec.ladder(short: short).lazy.filter { $0 > minute }.prefix(itemLookahead))
    }

    public func totalThresholds(after minute: Int) -> [Int] {
        Array(spec.totalMinutes.lazy.filter { $0 > minute }.prefix(totalLookahead))
    }

    public func totalNeedsRefill(crossed minute: Int, registeredUpTo: Int) -> Bool {
        registeredUpTo - minute < totalRefill
    }

    /// Activity names start with the epoch's prefix, so a heartbeat can tell which epoch is still registered.
    public static func prefix(for epochID: UUID) -> String {
        "st.\(epochID.uuidString.prefix(8).lowercased())."
    }

    /// Not ".total": that suffix marked tracking starts before rolling (see `JournalEntry.isTrackingStart`).
    public static func totalActivity(epochID: UUID) -> String {
        prefix(for: epochID) + "tot"
    }

    /// Items split evenly over up to `maxItemActivities` activities, so a roll re-registers only a few dozen.
    public static func itemActivities(epochID: UUID, itemIDs: [UUID]) -> [(name: String, itemIDs: [UUID])] {
        guard !itemIDs.isEmpty else { return [] }
        let count = min(maxItemActivities, itemIDs.count)
        let size = (itemIDs.count + count - 1) / count
        return stride(from: 0, to: itemIDs.count, by: size).enumerated().map { index, start in
            (prefix(for: epochID) + "r\(index)", Array(itemIDs[start..<min(start + size, itemIDs.count)]))
        }
    }
}
