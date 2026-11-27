import Foundation

/// When in the week the phone, or one app, is used: the average use in each hour of each weekday over the last four
/// weeks. Apple's samples fall within one hour each (`Sampler`), so a sample counts in its start's hour, and one day's
/// hour counts at most an hour: samples counted twice can't raise it past that. An hour is averaged over the days the
/// phone reported any use, up to now: a day without reports is unknown, not unused, and today's later hours haven't
/// happened yet.
public struct UsageHeatmap: Sendable, Hashable {
    public struct Cell: Sendable, Hashable {
        /// `Calendar`'s weekday: 1 is Sunday.
        public var weekday: Int
        public var hour: Int
        /// Average seconds of use in that hour; nil when no reported day covers it.
        public var seconds: Double?
        /// The reported days the average is over.
        public var days: Int

        public init(weekday: Int, hour: Int, seconds: Double?, days: Int) {
            self.weekday = weekday
            self.hour = hour
            self.seconds = seconds
            self.days = days
        }
    }

    public static let days = 28

    /// By weekday (index 0 is Sunday), then hour.
    public var cells: [[Cell]]
    /// The days out of the last 28, today too, the phone reported on.
    public var reportedDays: Int
    /// The busiest hour's average.
    public var max: Double

    public init(cells: [[Cell]], reportedDays: Int) {
        self.cells = cells
        self.reportedDays = reportedDays
        max = cells.joined().compactMap(\.seconds).max() ?? 0
    }

    public var isEmpty: Bool { max == 0 }

    public func cell(weekday: Int, hour: Int) -> Cell { cells[weekday - 1][hour] }

    /// The busiest hour of the week; nil when nothing was used.
    public var busiest: Cell? {
        cells.joined().filter { ($0.seconds ?? 0) > 0 }.max { ($0.seconds ?? 0) < ($1.seconds ?? 0) }
    }

    /// From each day's samples (all the kid's, any app), counting the ones `counts` picks.
    public static func build(today: DayKey, now: Date, calendar: Calendar = .current,
                             samples: (DayKey) -> [UsageSample], counts: (UsageSample) -> Bool) -> UsageHeatmap {
        var seconds = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)
        var covered = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        var reportedDays = 0
        for back in 0..<Self.days {
            let day = today.adding(days: -back, calendar: calendar)
            let all = samples(day)
            guard !all.isEmpty else { continue }
            reportedDays += 1
            let start = day.start(in: calendar)
            let weekday = calendar.component(.weekday, from: start) - 1
            for hour in 0..<24 {
                guard let hourStart = calendar.date(byAdding: .hour, value: hour, to: start), hourStart < now else { break }
                covered[weekday][hour] += 1
            }
            var byHour = [Int: [Int: Double]]()
            for sample in all where counts(sample) && sample.seconds > 0 {
                let parts = calendar.dateComponents([.weekday, .hour], from: sample.start)
                byHour[parts.weekday! - 1, default: [:]][parts.hour!, default: 0] += sample.seconds
            }
            for (weekday, hours) in byHour {
                for (hour, used) in hours { seconds[weekday][hour] += Swift.min(used, 3600) }
            }
        }
        let cells = (0..<7).map { weekday in
            (0..<24).map { hour in
                let days = covered[weekday][hour]
                return Cell(weekday: weekday + 1, hour: hour, seconds: days == 0 ? nil : seconds[weekday][hour] / Double(days),
                            days: days)
            }
        }
        return UsageHeatmap(cells: cells, reportedDays: reportedDays)
    }

    /// The minutes in an hour where each level from 2 to 4 starts.
    public static let levelMinutes = [5.0, 15, 30]

    /// How dark a cell is drawn, GitHub's way: 0 for no use, then 1 to 4 by fixed bands of minutes in the hour (under
    /// 5, 5 to 15, 15 to 30, 30 or more), so one busy hour doesn't make every other one look the same.
    public func level(_ cell: Cell) -> Int {
        guard let seconds = cell.seconds, seconds > 0 else { return 0 }
        return 1 + Self.levelMinutes.filter { seconds >= $0 * 60 }.count
    }
}
