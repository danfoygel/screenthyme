import Foundation

/// Threshold minutes for per-item ladders and the total ladder (PLAN.md §4.1).
public struct LadderSpec: Codable, Sendable, Hashable {
    /// Ascending.
    public var itemMinutes: [Int]
    /// Ascending.
    public var totalMinutes: [Int]
    /// The shorter ladder for websites, whose time mostly also counts as Safari's. nil: websites use `itemMinutes`.
    public var shortItemMinutes: [Int]?

    public init(itemMinutes: [Int], totalMinutes: [Int], shortItemMinutes: [Int]? = nil) {
        self.itemMinutes = itemMinutes
        self.totalMinutes = totalMinutes
        self.shortItemMinutes = shortItemMinutes
    }

    /// Apps and categories: every 5 min to 60, every 15 min to 12 h (56 events). Websites: every 5 min to 60 (12).
    /// Total: every minute to 16 h.
    public static let standard = LadderSpec(
        itemMinutes: Array(stride(from: 5, through: 60, by: 5)) + Array(stride(from: 75, through: 720, by: 15)),
        totalMinutes: Array(1...960),
        shortItemMinutes: Array(stride(from: 5, through: 60, by: 5))
    )

    public func ladder(short: Bool) -> [Int] {
        short ? (shortItemMinutes ?? itemMinutes) : itemMinutes
    }

    /// The threshold after `minute` on the item ladder, or nil past the top.
    public func nextItemStep(after minute: Int, short: Bool = false) -> Int? {
        ladder(short: short).first { $0 > minute }
    }

    /// The most minutes an item can have used beyond its last crossing `minute` without crossing again;
    /// 0 at the top of its ladder (where the use is open-ended instead).
    public func itemRemainder(after minute: Int, short: Bool = false) -> Int {
        guard let next = nextItemStep(after: minute, short: short) else { return 0 }
        return next - minute - 1
    }

    /// Snaps a parent-chosen threshold to the ladder step at or above it.
    public func snapItemThreshold(_ minutes: Int) -> Int {
        itemMinutes.first { $0 >= minutes } ?? itemMinutes.last ?? minutes
    }
}
