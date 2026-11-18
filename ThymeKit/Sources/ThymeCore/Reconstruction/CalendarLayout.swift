import Foundation

/// A block on the calendar-style timeline, drawn whole in swim lane `column` of `columns`: as many lanes as its group
/// of overlapping blocks needs.
public struct CalendarPiece: Sendable, Hashable, Identifiable {
    public var block: UsageBlock
    public var column: Int
    public var columns: Int

    public var id: String { block.id }
}

/// Lays out the day's blocks like events in a calendar, each a rectangle: a block alone is full width; blocks that
/// overlap (in use in the same fetch interval, at least) go in swim lanes side by side, all of one group of
/// overlapping blocks the same width. Apps keep the order they started in, and an app keeps its lane in a group while
/// it's free. Pure and deterministic.
public enum CalendarLayout {
    /// An app's blocks closer together than this are joined: a pause shorter than one step of the wake alarm.
    public static let joinGap: TimeInterval = 120

    /// The blocks the calendar shows: each app's blocks joined across short pauses, then those under `minimum`
    /// left out. Two blocks join when they're under `joinGap` apart, both placed or both guessed, and no other app's
    /// block that's shown lies in the pause between them (a short one that's left out doesn't count).
    public static func visible(_ blocks: [UsageBlock], minimum: TimeInterval = 0) -> [UsageBlock] {
        // What's shown depends on the joining, and the joining on what's shown: judge the pauses by the blocks that
        // would be shown if every app were joined freely.
        let shownFreely = join(blocks) { _, _ in true }.filter { $0.seconds >= minimum }
        let joined = join(blocks) { before, after in
            !shownFreely.contains { $0.itemID != before.itemID && $0.start < after.start && $0.end > before.end }
        }
        return joined.filter { $0.seconds >= minimum }
    }

    static func join(_ blocks: [UsageBlock], allowed: (UsageBlock, UsageBlock) -> Bool) -> [UsageBlock] {
        var result: [UsageBlock] = []
        for (_, itemBlocks) in Dictionary(grouping: blocks, by: \.itemID) {
            var current: UsageBlock?
            for block in itemBlocks.sorted(by: { $0.start < $1.start }) {
                if var run = current, (run.somewhereIn == nil) == (block.somewhereIn == nil),
                   block.start.timeIntervalSince(run.end) < joinGap, allowed(run, block) {
                    run.end = max(run.end, block.end)
                    run.seconds += block.seconds
                    if let window = block.somewhereIn, let earlier = run.somewhereIn {
                        run.somewhereIn = DateInterval(start: min(earlier.start, window.start),
                                                       end: max(earlier.end, window.end))
                    }
                    current = run
                } else {
                    if let current { result.append(current) }
                    current = block
                }
            }
            if let current { result.append(current) }
        }
        return result.sorted { ($0.start, $0.end, $0.seconds) < ($1.start, $1.end, $1.seconds) }
    }

    public static func place(_ blocks: [UsageBlock]) -> [CalendarPiece] {
        let blocks = blocks.filter { $0.end > $0.start }.sorted {
            ($0.start, $0.itemID.uuidString) < ($1.start, $1.itemID.uuidString)
        }
        var pieces: [CalendarPiece] = []
        var group: [CalendarPiece] = []
        /// When each lane of the group comes free, and the lane each app was last in.
        var lanes: [Date] = []
        var lastLane: [UUID: Int] = [:]
        func close() {
            pieces += group.map { CalendarPiece(block: $0.block, column: $0.column, columns: lanes.count) }
            group = []
            lanes = []
            lastLane = [:]
        }
        for block in blocks {
            if let groupEnd = lanes.max(), block.start >= groupEnd { close() }
            let lane = lastLane[block.itemID].flatMap { lanes[$0] <= block.start ? $0 : nil }
                ?? lanes.firstIndex { $0 <= block.start }
                ?? lanes.count
            if lane == lanes.count { lanes.append(block.end) } else { lanes[lane] = block.end }
            lastLane[block.itemID] = lane
            group.append(CalendarPiece(block: block, column: lane, columns: 0))
        }
        close()
        return pieces
    }
}
