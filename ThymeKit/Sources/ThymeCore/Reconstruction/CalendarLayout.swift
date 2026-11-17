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
