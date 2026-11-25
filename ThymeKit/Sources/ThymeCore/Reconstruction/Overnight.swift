import Foundation

/// The night's rest: the longest pause in use that covers part of the small hours, from the last use the evening
/// before to the first use the morning after ("not used 9:30 PM – 7:45 AM").
public enum Overnight {
    /// Shorter pauses aren't a night.
    public static let minimum: TimeInterval = 3 * 3600
    /// The pause overlaps the hours from midnight to this.
    public static let smallHoursEnd: TimeInterval = 6 * 3600

    /// `yesterday` and `today` are each day's runs of use (`DayTimeline.runs`); `dayStart` is today's midnight.
    /// Nil until there's been use on both sides of the night.
    public static func rest(yesterday: [DateInterval], today: [DateInterval], dayStart: Date) -> DateInterval? {
        let smallHours = DateInterval(start: dayStart, duration: smallHoursEnd)
        let runs = (yesterday + today).sorted { $0.start < $1.start }
        let pauses = zip(runs, runs.dropFirst()).compactMap { before, after in
            after.start > before.end ? DateInterval(start: before.end, end: after.start) : nil
        }
        return pauses
            .filter { $0.duration >= minimum && $0.start < smallHours.end && $0.end > smallHours.start }
            .max { $0.duration < $1.duration }
    }
}
