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
        let firedIDs = moved.entries.compactMap { $0.parsedEvent?.itemID }
        #expect(firedIDs.allSatisfy { movedIDs.contains($0) })
        #expect(moved.entries.first!.at.timeIntervalSince(trace.entries.first!.at) == 3 * 86400)
        #expect(moved.fires(calendar: utc).allSatisfy { $0.day == target && $0.kidID == fake.id })

        // Deterministic: replaying twice yields the same record ids.
        let again = Replay.retarget(trace, to: fake, day: target, calendar: utc)
        #expect(again.entries.map(\.id) == moved.entries.map(\.id))
    }

    @Test func reconstructionSurvivesRetarget() {
        let trace = SyntheticScenario.schoolDay.trace(kid: source, day: testDay, calendar: utc)
        let target = testDay.adding(days: 1, calendar: utc)
        let moved = Replay.retarget(trace, to: fake, day: target, calendar: utc)
        let before = Reconstructor.build(DayInput(fires: trace.fires(calendar: utc), dayStart: dayStart))
        let after = Reconstructor.build(DayInput(fires: moved.fires(calendar: utc), dayStart: target.start(in: utc)))
        #expect(before.totalMinutes == after.totalMinutes)
        #expect(before.segments.map(\.minutes) == after.segments.map(\.minutes))
    }

    @Test func traceRoundTrips() throws {
        let trace = SyntheticScenario.bedtime.trace(kid: source, day: testDay, calendar: utc)
        let decoded = try Trace.decode(trace.encoded())
        #expect(decoded.entries == trace.entries)
        #expect(decoded.items == trace.items)
    }

    @Test func schedules() {
        let fires = [
            UsageFire(id: UUID(), kidID: fake.id, itemID: nil, minute: 1, firedAt: at(10, 0), day: testDay, epochID: nil),
            UsageFire(id: UUID(), kidID: fake.id, itemID: nil, minute: 2, firedAt: at(10, 1), day: testDay, epochID: nil),
        ]
        #expect(Replay.schedule(fires, speed: .instant, now: at(9, 0)).map(\.delay) == [0, 0])
        #expect(Replay.schedule(fires, speed: .realTime, now: at(10, 0, 30)).map(\.delay) == [0, 30])
        #expect(Replay.schedule(fires, speed: .accelerated(60), now: at(12, 0)).map(\.delay) == [0, 1])
    }
}
