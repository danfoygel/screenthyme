import Foundation
@testable import ThymeCore

/// Fixed UTC Gregorian calendar so tests don't depend on the machine's time zone.
let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

let testDay = DayKey(year: 2026, month: 11, day: 14)
let dayStart = testDay.start(in: utc)

func at(_ hour: Int, _ minute: Int, _ second: Double = 0) -> Date {
    dayStart.addingTimeInterval(Double(hour * 3600 + minute * 60) + second)
}

func timeline(_ sessions: [SyntheticSession], options: SyntheticOptions = SyntheticOptions()) -> DayTimeline {
    let entries = SyntheticTrace.entries(sessions: sessions, options: options)
    return Reconstructor.build(DayInput(entries: entries, dayStart: dayStart))
}

extension DayTimeline {
    func segments(for item: UUID) -> [Segment] {
        segments.filter { $0.owner == .item(item) }
    }

    func minutes(for item: UUID, atLeast confidence: Confidence = .low) -> Int {
        segments(for: item).filter { $0.confidence >= confidence }.reduce(0) { $0 + $1.minutes }
    }
}
