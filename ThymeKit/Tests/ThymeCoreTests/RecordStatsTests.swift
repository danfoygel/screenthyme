import Foundation
import Testing
@testable import ThymeCore

struct RecordStatsTests {
    let now = at(15, 0)

    func daysAgo(_ days: Int, hour: Int = 12) -> Date {
        utc.date(byAdding: .day, value: -days, to: at(hour, 0))!
    }

    @Test func bucketsAgeByCalendarDay() {
        #expect(RecordAge(of: at(0, 1), now: now, calendar: utc) == .today)
        #expect(RecordAge(of: daysAgo(1, hour: 23), now: now, calendar: utc) == .lastWeek)
        #expect(RecordAge(of: daysAgo(7), now: now, calendar: utc) == .lastWeek)
        #expect(RecordAge(of: daysAgo(8), now: now, calendar: utc) == .lastMonth)
        #expect(RecordAge(of: daysAgo(30), now: now, calendar: utc) == .lastMonth)
        #expect(RecordAge(of: daysAgo(31), now: now, calendar: utc) == .lastQuarter)
        #expect(RecordAge(of: daysAgo(91), now: now, calendar: utc) == .older)
        #expect(RecordAge(of: nil, now: now, calendar: utc) == .unknown)
        // A clock a little ahead on another phone still counts as today.
        #expect(RecordAge(of: now.addingTimeInterval(60), now: now, calendar: utc) == .today)
    }

    @Test func talliesByKidTypeAndAge() {
        let other = UUID()
        let records = [
            RecordSummary(type: "UsageSample", kidID: testKid.id, bytes: 300, createdAt: at(9, 0)),
            RecordSummary(type: "UsageSample", kidID: testKid.id, bytes: 200, createdAt: daysAgo(3)),
            RecordSummary(type: "UsageFire", kidID: other, bytes: 100, createdAt: daysAgo(40)),
            RecordSummary(type: "LinkKey", kidID: nil, bytes: 50, createdAt: nil),
        ]
        let stats = RecordStats(records, now: now, calendar: utc)

        #expect(stats.total == RecordTally(count: 4, bytes: 650))
        #expect(stats.byKid[testKid.id] == RecordTally(count: 2, bytes: 500))
        #expect(stats.byKid[other] == RecordTally(count: 1, bytes: 100))
        #expect(stats.byKid[nil] == RecordTally(count: 1, bytes: 50))
        #expect(stats.typesBySize.map(\.type) == ["UsageSample", "UsageFire", "LinkKey"])
        #expect(stats.ages.map(\.age) == [.today, .lastWeek, .lastQuarter, .unknown])
        #expect(stats.byAge[.lastWeek] == RecordTally(count: 1, bytes: 200))
    }

    @Test func breaksSizeTiesByName() {
        let records = ["B", "A"].map { RecordSummary(type: $0, kidID: nil, bytes: 10, createdAt: nil) }
        #expect(RecordStats(records).typesBySize.map(\.type) == ["A", "B"])
    }
}
