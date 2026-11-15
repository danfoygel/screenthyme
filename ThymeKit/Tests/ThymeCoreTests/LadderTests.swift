import Foundation
import Testing
@testable import ThymeCore

struct EventNameTests {
    @Test func roundTrip() {
        let id = UUID()
        #expect(EventName.parse(EventName.item(id, minute: 45)) == EventName.Parsed(itemID: id, minute: 45))
        #expect(EventName.parse(EventName.total(minute: 7)) == EventName.Parsed(itemID: nil, minute: 7))
        #expect(EventName.parse("x.1") == nil)
        #expect(EventName.parse("i.not-a-uuid.5") == nil)
    }
}

struct RollingLadderTests {
    let ladder = RollingLadder()

    @Test func wakesEveryStep() {
        #expect(ladder.thresholds(after: 0) == [2, 4, 6, 8, 10, 12, 14, 16, 18, 20])
        #expect(ladder.thresholds(after: 77) == Array(stride(from: 78, through: 96, by: 2)))
        #expect(ladder.thresholds(after: 1437) == [1438, 1440])
        #expect(RollingLadder(step: 1, lookahead: 3).thresholds(after: 5) == [6, 7, 8])
    }

    @Test func refillsAtHalfWindow() {
        #expect(!ladder.needsRefill(crossed: 4, registeredUpTo: 20))
        #expect(ladder.needsRefill(crossed: 10, registeredUpTo: 20))
    }

    @Test func activityNameIsNotLegacyTotal() {
        let epoch = UUID()
        #expect(RollingLadder.activityName(epochID: epoch).hasPrefix(RollingLadder.prefix(for: epoch)))
        #expect(!RollingLadder.activityName(epochID: epoch).hasSuffix(".total"))
    }
}

struct MonitorDayStateTests {
    @Test func recordsRunsAndResetsDaily() {
        var state = MonitorDayState(day: testDay)
        let app = UUID()
        state.record(WakeObservation(at: at(10, 0), totalMinute: 2, itemSeconds: [app: 100], intervalSeconds: [app: 100]),
                     calendar: utc)
        state.record(WakeObservation(at: at(10, 2), totalMinute: 4, itemSeconds: [app: 220], intervalSeconds: [app: 120]),
                     calendar: utc)
        #expect(state.totalMinute == 4 && state.itemSeconds[app] == 220 && state.runSeconds[app] == 220)
        #expect(state.runStart == at(9, 59))
        // A long pause starts a new run.
        state.record(WakeObservation(at: at(11, 0), totalMinute: 6, intervalSeconds: [app: 60]), calendar: utc)
        #expect(state.runStart == at(10, 59) && state.runSeconds[app] == 60)
        state.record(WakeObservation(at: at(24, 1), totalMinute: 2), calendar: utc)
        #expect(state.day == testDay.adding(days: 1, calendar: utc))
        #expect(state.totalMinute == 2 && state.itemSeconds.isEmpty)
    }
}
