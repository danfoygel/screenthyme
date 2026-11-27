import Foundation
import Testing
@testable import ThymeCore

struct UsageHeatmapTests {
    let app = UUID()
    let other = UUID()

    func sample(_ item: UUID, _ day: DayKey, hour: Int, _ seconds: Double) -> UsageSample {
        let start = day.start(in: utc).addingTimeInterval(Double(hour) * 3600 + 60)
        return UsageSample(id: UUID(), kidID: testKid.id, itemID: item, day: day, start: start,
                           end: start.addingTimeInterval(seconds), seconds: seconds)
    }

    /// testDay, 2026-11-14, is a Saturday.
    @Test func averagesEachHourOverTheReportedDaysOfItsWeekday() {
        let lastWeek = testDay.adding(days: -7, calendar: utc)
        let twoWeeks = testDay.adding(days: -14, calendar: utc)
        let friday = testDay.adding(days: -1, calendar: utc)
        let old = testDay.adding(days: -28, calendar: utc)
        let byDay: [DayKey: [UsageSample]] = [
            lastWeek: [sample(app, lastWeek, hour: 20, 1200), sample(other, lastWeek, hour: 9, 600)],
            twoWeeks: [sample(app, twoWeeks, hour: 20, 600)],
            friday: [sample(other, friday, hour: 8, 60)],
            // Older than four weeks.
            old: [sample(app, old, hour: 20, 9000)],
        ]
        let map = UsageHeatmap.build(today: testDay, now: at(12, 30), calendar: utc, samples: { byDay[$0] ?? [] },
                                     counts: { $0.itemID == app })
        #expect(map.reportedDays == 3)
        // Two Saturdays reported; today didn't, so it isn't counted.
        #expect(map.cell(weekday: 7, hour: 20) == .init(weekday: 7, hour: 20, seconds: 900, days: 2))
        #expect(map.cell(weekday: 7, hour: 9).seconds == 0)
        // Friday reported other apps only.
        #expect(map.cell(weekday: 6, hour: 20) == .init(weekday: 6, hour: 20, seconds: 0, days: 1))
        #expect(map.cell(weekday: 1, hour: 20).seconds == nil)
        #expect(map.max == 900)
        #expect(map.busiest?.hour == 20)
        #expect(map.level(map.cell(weekday: 7, hour: 20)) == 3)
        #expect(map.level(map.cell(weekday: 6, hour: 20)) == 0)
    }

    @Test func todayCountsOnlyTheHoursThatHaveBegun() {
        let lastWeek = testDay.adding(days: -7, calendar: utc)
        let byDay: [DayKey: [UsageSample]] = [
            testDay: [sample(app, testDay, hour: 10, 300)],
            lastWeek: [sample(app, lastWeek, hour: 10, 100), sample(app, lastWeek, hour: 18, 1800)],
        ]
        let map = UsageHeatmap.build(today: testDay, now: at(12, 30), calendar: utc, samples: { byDay[$0] ?? [] },
                                     counts: { _ in true })
        #expect(map.cell(weekday: 7, hour: 10) == .init(weekday: 7, hour: 10, seconds: 200, days: 2))
        #expect(map.cell(weekday: 7, hour: 12).days == 2)
        #expect(map.cell(weekday: 7, hour: 18) == .init(weekday: 7, hour: 18, seconds: 1800, days: 1))
        #expect(map.level(map.cell(weekday: 7, hour: 10)) == 1)
    }

    @Test func oneDaysHourCountsAtMostAnHour() {
        let lastWeek = testDay.adding(days: -7, calendar: utc)
        let byDay: [DayKey: [UsageSample]] = [
            lastWeek: [sample(app, lastWeek, hour: 0, 3600), sample(app, lastWeek, hour: 0, 3600),
                       sample(other, lastWeek, hour: 0, 3600), sample(app, lastWeek, hour: 1, 600)],
            testDay: [sample(app, testDay, hour: 0, 600)],
        ]
        let map = UsageHeatmap.build(today: testDay, now: at(12, 30), calendar: utc, samples: { byDay[$0] ?? [] },
                                     counts: { _ in true })
        // Three hours of samples in one hour count as one; today's 10 min still adds.
        #expect(map.cell(weekday: 7, hour: 0) == .init(weekday: 7, hour: 0, seconds: (3600 + 600) / 2, days: 2))
        #expect(map.max <= 3600)
    }

    @Test func oneBusyHourDoesntFlattenTheRest() {
        let days = (1...4).map { testDay.adding(days: -7 * $0, calendar: utc) }
        var byDay = [DayKey: [UsageSample]]()
        for day in days { byDay[day] = (8..<22).map { sample(app, day, hour: $0, 600) } }
        byDay[days[0]]!.append(sample(app, days[0], hour: 0, 3 * 3600))
        let map = UsageHeatmap.build(today: testDay, now: at(23, 30), calendar: utc, samples: { byDay[$0] ?? [] },
                                     counts: { _ in true })
        #expect(map.level(map.cell(weekday: 7, hour: 0)) == 3)
        #expect((8..<22).allSatisfy { map.level(map.cell(weekday: 7, hour: $0)) == 2 })
    }

    @Test func levelsAreFixedBandsOfMinutes() {
        let map = UsageHeatmap(cells: [], reportedDays: 0)
        let levels = [0.0, 3, 10, 20, 45].map { map.level(.init(weekday: 1, hour: 0, seconds: $0 * 60, days: 1)) }
        #expect(levels == [0, 1, 2, 3, 4])
        #expect(map.level(.init(weekday: 1, hour: 0, seconds: nil, days: 0)) == 0)
    }

    @Test func emptyWithoutUse() {
        let map = UsageHeatmap.build(today: testDay, now: at(12, 0), calendar: utc, samples: { _ in [] }, counts: { _ in true })
        #expect(map.isEmpty && map.busiest == nil && map.reportedDays == 0)
        #expect(map.cells.joined().allSatisfy { $0.seconds == nil })
    }
}
