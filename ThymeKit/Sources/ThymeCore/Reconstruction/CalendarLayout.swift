import Foundation

/// Part of a block on the calendar-style timeline: from `start` to `end` the block shares the width with
/// `columns - 1` other apps and sits in `column`.
public struct CalendarPiece: Sendable, Hashable, Identifiable {
    public var block: UsageBlock
    public var start: Date
    public var end: Date
    public var column: Int
    public var columns: Int
    /// The block's longest piece, where its name goes.
    public var isLabeled: Bool

    public var id: String { "\(block.id)-\(start.timeIntervalSince1970)" }
}

/// Lays out the day's blocks like events in a calendar: a stretch with one app in use is one full-width rectangle;
/// where apps were in use in the same stretch (the same fetch interval, at least), they sit side by side for just
/// that stretch. Apps keep the order they started in. Pure and deterministic.
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
        let bounds = Set(blocks.flatMap { [$0.start, $0.end] }).sorted()
        var pieces: [CalendarPiece] = []
        /// Each block's latest piece, extended while its column and company stay the same.
        var current: [Int: Int] = [:]
        for (start, end) in zip(bounds, bounds.dropFirst()) {
            let active = blocks.indices.filter { blocks[$0].start < end && blocks[$0].end > start }
            for (column, index) in active.enumerated() {
                if let last = current[index], pieces[last].end == start,
                   pieces[last].column == column, pieces[last].columns == active.count {
                    pieces[last].end = end
                } else {
                    current[index] = pieces.count
                    pieces.append(CalendarPiece(block: blocks[index], start: start, end: end, column: column,
                                                columns: active.count, isLabeled: false))
                }
            }
        }
        let longest = Dictionary(grouping: pieces.indices, by: { pieces[$0].block.id }).values.compactMap { indices in
            indices.max { pieces[$0].end.timeIntervalSince(pieces[$0].start) < pieces[$1].end.timeIntervalSince(pieces[$1].start) }
        }
        for index in longest { pieces[index].isLabeled = true }
        return pieces
    }
}
