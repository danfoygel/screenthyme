import Foundation

/// A daily time window by minutes of day, possibly wrapping past midnight, on some weekdays (of the day it starts).
/// Shared by quiet-hours rules and Downtime.
public struct DailyWindow: Sendable, Hashable {
    public var startMinute: Int
    public var endMinute: Int
    /// Calendar numbering (1 = Sunday); empty means every day.
    public var weekdays: Set<Int>

    public init(startMinute: Int, endMinute: Int, weekdays: Set<Int> = []) {
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.weekdays = weekdays
    }

    public var wraps: Bool { endMinute < startMinute }

    /// The occurrence containing `date`, or nil if `date` is outside every occurrence.
    public func occurrence(containing date: Date, calendar: Calendar = .current) -> DateInterval? {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minuteOfDay = parts.hour! * 60 + parts.minute!
        let today = calendar.startOfDay(for: date)
        let day: Date
        if !wraps {
            guard minuteOfDay >= startMinute, minuteOfDay < endMinute else { return nil }
            day = today
        } else if minuteOfDay >= startMinute {
            day = today
        } else if minuteOfDay < endMinute {
            day = calendar.date(byAdding: .day, value: -1, to: today)!
        } else {
            return nil
        }
        guard weekdays.isEmpty || weekdays.contains(calendar.component(.weekday, from: day)) else { return nil }
        let start = calendar.date(byAdding: .minute, value: startMinute, to: day)!
        let endDay = wraps ? calendar.date(byAdding: .day, value: 1, to: day)! : day
        let end = calendar.date(byAdding: .minute, value: endMinute, to: endDay)!
        return DateInterval(start: start, end: end)
    }
}

extension DowntimeWindow {
    public var daily: DailyWindow { DailyWindow(startMinute: startMinute, endMinute: endMinute, weekdays: weekdays) }
}
