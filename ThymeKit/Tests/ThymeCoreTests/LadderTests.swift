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
        #expect(EventName.parseProbe(EventName.probe(minute: 168)) == 168)
        #expect(EventName.parse(EventName.probe(minute: 168)) == nil)
        #expect(EventName.parseProbe(EventName.total(minute: 168)) == nil)
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

    @Test func probesHalveTowardZero() {
        #expect(ladder.probes(below: 200) == [2, 72, 136, 168, 184, 192, 196, 198])
        #expect(ladder.probes(below: 5) == [1, 2, 3])
        #expect(ladder.probes(below: 2).isEmpty)
        #expect(ladder.probes(below: 0).isEmpty)
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

struct LadderCalibrationTests {
    let registered = at(9, 0)

    /// Probes replay in random order; the highest one settles.
    func settled(base: Int, passing probes: [Int], at date: Date? = nil) -> (LadderCalibration, Int?) {
        var calibration = LadderCalibration(base: base, registeredAt: registered)
        for probe in probes {
            let passed = calibration.probePassed(probe, at: registered.addingTimeInterval(1))
            #expect(passed)
        }
        let after = calibration.settle(at: date ?? registered.addingTimeInterval(4), step: 2)
        return (calibration, after)
    }

    @Test func countWhereOursIsChangesNothing() {
        let (calibration, after) = settled(base: 200, passing: [168, 198, 2, 72, 192, 136, 196, 184])
        #expect(after == nil && calibration.offset == 0)
    }

    /// After a new grant iOS counts less than we do.
    @Test func lowerCountMovesTheLadderDown() {
        var (calibration, after) = settled(base: 200, passing: [136, 2, 184, 168])
        #expect(after == 184 && calibration.offset == 16)
        // The ladder from 186 replays what iOS passed between probes: those refine the offset and aren't use.
        let replay = calibration.ladderFired(186, at: registered.addingTimeInterval(6))
        #expect(replay == nil && calibration.offset == 14)
        // Afterwards fires are use, in our minutes.
        let use = calibration.ladderFired(188, at: registered.addingTimeInterval(300))
        #expect(use == 202)
    }

    @Test func lateProbesAreIgnored() {
        var calibration = LadderCalibration(base: 200, registeredAt: registered)
        let passed = calibration.probePassed(168, at: registered.addingTimeInterval(LadderCalibration.replayWindow + 1))
        let after = calibration.settle(at: registered.addingTimeInterval(65), step: 2)
        #expect(!passed && after == nil)
    }

    @Test func topProbeAfterALowOneMovesTheLadderBack() {
        var (calibration, _) = settled(base: 200, passing: [136])
        #expect(calibration.offset == 64)
        let passed = calibration.probePassed(198, at: registered.addingTimeInterval(8))
        let after = calibration.settle(at: registered.addingTimeInterval(11), step: 2)
        #expect(passed && after == 200 && calibration.offset == 0)
    }

    @Test func replaysWithoutAnOffsetAreUse() {
        // iOS ahead of us (a missed fire): the registration's catch-up, as before.
        var calibration = LadderCalibration(base: 100, registeredAt: registered)
        let use = calibration.ladderFired(102, at: registered.addingTimeInterval(1))
        #expect(use == 102)
    }

    @Test func surviveARoundTrip() throws {
        let (calibration, _) = settled(base: 200, passing: [168])
        let data = try JSONEncoder.thyme.encode(calibration)
        #expect(try JSONDecoder.thyme.decode(LadderCalibration.self, from: data) == calibration)
    }
}
