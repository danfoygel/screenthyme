import Foundation

/// A calendar day ("2026-11-14") in the kid device's calendar. Daily ladders reset at its start.
public struct DayKey: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year!, month: parts.month!, day: parts.day!)
    }

    public init?(string: String) {
        let parts = string.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        self.init(year: parts[0], month: parts[1], day: parts[2])
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public func start(in calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// The start of the following day.
    public func end(in calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 1, to: start(in: calendar))!
    }

    public func adding(days: Int, calendar: Calendar = .current) -> DayKey {
        DayKey(calendar.date(byAdding: .day, value: days, to: start(in: calendar))!, calendar: calendar)
    }

    public static func < (lhs: DayKey, rhs: DayKey) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

extension DayKey: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let key = DayKey(string: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Bad day key \(string)")
        }
        self = key
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
