import Foundation

/// Threshold minutes for per-item ladders and the total ladder (PLAN.md §4.1).
public struct LadderSpec: Codable, Sendable, Hashable {
    /// Ascending.
    public var itemMinutes: [Int]
    /// Ascending.
    public var totalMinutes: [Int]

    public init(itemMinutes: [Int], totalMinutes: [Int]) {
        self.itemMinutes = itemMinutes
        self.totalMinutes = totalMinutes
    }

    /// Every 5 min to 60, every 15 min to 12 h (56 events per item); total every minute to 16 h.
    public static let standard = LadderSpec(
        itemMinutes: Array(stride(from: 5, through: 60, by: 5)) + Array(stride(from: 75, through: 720, by: 15)),
        totalMinutes: Array(1...960)
    )

    /// The threshold after `minute` on the item ladder, or nil past the top.
    public func nextItemStep(after minute: Int) -> Int? {
        itemMinutes.first { $0 > minute }
    }

    /// The most minutes an item can have used beyond its last crossing `minute` without crossing again.
    public func itemRemainder(after minute: Int) -> Int {
        guard let next = nextItemStep(after: minute) else { return 0 }
        return next - minute - 1
    }

    /// Snaps a parent-chosen threshold to the ladder step at or above it.
    public func snapItemThreshold(_ minutes: Int) -> Int {
        itemMinutes.first { $0 >= minutes } ?? itemMinutes.last ?? minutes
    }
}
