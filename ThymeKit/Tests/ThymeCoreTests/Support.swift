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
let testKid = Kid(displayName: "Emma")

func at(_ hour: Int, _ minute: Int, _ second: Double = 0) -> Date {
    dayStart.addingTimeInterval(Double(hour * 3600 + minute * 60) + second)
}

func timeline(_ sessions: [SyntheticSession], options: SyntheticOptions = SyntheticOptions()) -> (DayInput, DayTimeline) {
    let (entries, samples) = SyntheticTrace.generate(kid: testKid.id, sessions: sessions, options: options, calendar: utc)
    let input = DayInput(entries: entries, samples: samples, dayStart: dayStart)
    return (input, Reconstructor.build(input))
}
