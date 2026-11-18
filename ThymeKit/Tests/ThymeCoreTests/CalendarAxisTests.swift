import Foundation
import Testing
@testable import ThymeCore

struct CalendarAxisTests {
    let day = DateInterval(start: at(0, 0), end: at(24, 0))

    func kept(_ start: Date, _ end: Date) -> DateInterval { DateInterval(start: start, end: end) }

    /// Use from 7:03 to 8:20 (with a short pause) and 13:12 to 13:30, at 120 points per hour.
    var axis: CalendarAxis {
        CalendarAxis(day: day, scale: 120, keep: [kept(at(7, 3), at(7, 40)), kept(at(7, 55), at(8, 20)),
                                                  kept(at(13, 12), at(13, 30))])
    }

    @Test func longBlankStretchesAreCutOutLeavingAMargin() {
        let segments = axis.segments
        #expect(segments.map(\.isBreak) == [true, false, true, false, true])
        // 15-minute margins, rounded out to 5 minutes; the day's edges stay put.
        #expect(segments.map(\.interval.start) == [at(0, 0), at(6, 45), at(8, 35), at(12, 55), at(13, 45)])
        #expect(segments.last?.interval.end == at(24, 0))
        #expect(segments.map(\.height) == [28, 220, 28, 100, 28])
        #expect(axis.height == 404)
    }

    @Test func shortPausesAreNotCut() {
        let axis = CalendarAxis(day: day, scale: 120, keep: [kept(at(9, 0), at(9, 10)), kept(at(9, 50), at(10, 0))])
        // 40 minutes apart: 10 minutes once the margins are kept, too little to cut.
        #expect(axis.segments.filter { !$0.isBreak }.map(\.interval) == [kept(at(8, 45), at(10, 15))])
    }

    @Test func zoomingInCutsShorterStretches() {
        let keep = [kept(at(9, 0), at(9, 10)), kept(at(10, 0), at(10, 10))]
        #expect(CalendarAxis(day: day, scale: 120, keep: keep).breaks.count == 2)
        #expect(CalendarAxis(day: day, scale: 960, keep: keep).breaks.count == 3)
    }

    @Test func nothingKeptIsTheWholeDay() {
        let axis = CalendarAxis(day: day, scale: 30, keep: [])
        #expect(axis.segments.count == 1 && axis.height == 720)
    }

    @Test func yAndDateAreInverses() {
        let axis = self.axis
        for date in [at(0, 0), at(3, 0), at(6, 45), at(7, 10), at(8, 35), at(10, 0), at(13, 20), at(20, 0), at(24, 0)] {
            #expect(abs(axis.date(at: axis.y(date)).timeIntervalSince(date)) < 0.001)
        }
        #expect(axis.y(at(7, 0)) == 58)
        // Time in a break lands on it in proportion.
        #expect(axis.y(at(10, 45)) == 248 + 14)
        let ys = stride(from: 0.0, through: 86400, by: 600).map { axis.y(at(0, 0).addingTimeInterval($0)) }
        #expect(zip(ys, ys.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test func ticksGetFinerWithZoomAndSkipBreaks() {
        #expect(axis.ticks(spacing: 24) == [at(7, 0), at(7, 15), at(7, 30), at(7, 45), at(8, 0), at(8, 15), at(8, 30),
                                            at(13, 0), at(13, 15), at(13, 30)])
        let whole = CalendarAxis(day: day, scale: 30, keep: [])
        #expect(whole.ticks(spacing: 24).count == 25)
        let close = CalendarAxis(day: day, scale: 960, keep: [])
        #expect(close.ticks(spacing: 24).count == 24 * 12 + 1)
    }
}
