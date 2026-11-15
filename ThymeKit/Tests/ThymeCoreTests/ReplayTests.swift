import Foundation
import Testing
@testable import ThymeCore

struct ReplayTests {
    let source = Kid(displayName: "Me")
    let fake = Kid(displayName: "Leo", isTest: true)

    @Test func retargetRemapsIdsAndShiftsDay() throws {
        let trace = SyntheticScenario.schoolDay.trace(kid: source, day: testDay, calendar: utc)
        let target = testDay.adding(days: 3, calendar: utc)
        let moved = Replay.retarget(trace, to: fake, day: target, calendar: utc)

        #expect(moved.kid == fake)
        #expect(moved.items.allSatisfy { $0.kidID == fake.id })
        #expect(Set(moved.items.map(\.id)).isDisjoint(with: trace.items.map(\.id)))
        let movedIDs = Set(moved.items.map(\.id))
        #expect(moved.samples.allSatisfy { movedIDs.contains($0.itemID) && $0.kidID == fake.id && $0.day == target })
        #expect(moved.entries.first!.at.timeIntervalSince(trace.entries.first!.at) == 3 * 86400)
        #expect(moved.fires(calendar: utc).allSatisfy { $0.day == target && $0.kidID == fake.id })

        let again = Replay.retarget(trace, to: fake, day: target, calendar: utc)
        #expect(again.samples.map(\.id) == moved.samples.map(\.id))
    }

    @Test func reconstructionSurvivesRetarget() {
        let trace = SyntheticScenario.schoolDay.trace(kid: source, day: testDay, calendar: utc)
        let target = testDay.adding(days: 1, calendar: utc)
        let moved = Replay.retarget(trace, to: fake, day: target, calendar: utc)
        let before = Reconstructor.build(DayInput(fires: trace.fires(calendar: utc), samples: trace.samples, dayStart: dayStart))
        let after = Reconstructor.build(DayInput(fires: moved.fires(calendar: utc), samples: moved.samples,
                                                 dayStart: target.start(in: utc)))
        #expect(before.totalMinutes == after.totalMinutes)
        #expect(before.appMinutes == after.appMinutes)
        #expect(before.blocks.map(\.seconds) == after.blocks.map(\.seconds))
    }

    @Test func traceRoundTrips() throws {
        let trace = SyntheticScenario.bedtime.trace(kid: source, day: testDay, calendar: utc)
        let decoded = try Trace.decode(trace.encoded())
        #expect(decoded.entries == trace.entries)
        #expect(decoded.samples == trace.samples)
        #expect(decoded.items == trace.items)
    }

    @Test func delays() {
        let times = [at(10, 0), at(10, 1)]
        #expect(Replay.delays(for: times, speed: .instant, now: at(9, 0)) == [0, 0])
        #expect(Replay.delays(for: times, speed: .realTime, now: at(10, 0, 30)) == [0, 30])
        #expect(Replay.delays(for: times, speed: .accelerated(60), now: at(12, 0)) == [0, 1])
    }
}
