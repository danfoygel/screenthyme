import Foundation
import Testing
@testable import ThymeCore

struct ReconstructionTests {
    let youtube = UUID(), roblox = UUID(), tiktok = UUID()

    @Test func singleContinuousSession() {
        let result = timeline([SyntheticSession(item: youtube, start: at(16, 0), minutes: 30)])
        #expect(result.totalMinutes == 30)
        #expect(result.totals[youtube]?.lowerMinutes == 30)
        #expect(result.totals[youtube]?.upperMinutes == 34)
        #expect(result.minutes(for: youtube, atLeast: .high) == 30)
        #expect(result.segments(for: youtube).count == 1)
        #expect(result.segments(for: youtube).first?.start == at(16, 0))
        #expect(result.unexplainedMinutes == 0)
        #expect(result.suspectFires == 0)
    }

    @Test func sequentialAppsSplitAtBoundary() {
        let result = timeline([
            SyntheticSession(item: youtube, start: at(16, 0), minutes: 20),
            SyntheticSession(item: roblox, start: at(16, 20), minutes: 15),
        ])
        #expect(result.minutes(for: youtube, atLeast: .high) == 20)
        #expect(result.minutes(for: roblox, atLeast: .high) == 15)
        #expect(result.segments(for: roblox).first?.start == at(16, 20))
        #expect(result.runs.count == 1)
    }

    @Test func separateRunsBecomeSeparateSessions() {
        let result = timeline([
            SyntheticSession(item: youtube, start: at(9, 0), minutes: 10),
            SyntheticSession(item: youtube, start: at(15, 0), minutes: 10),
        ])
        #expect(result.runs.count == 2)
        #expect(result.segments(for: youtube).count == 2)
        #expect(result.minutes(for: youtube) == 20)
    }

    @Test func ladderTailIsLowConfidence() {
        let result = timeline([SyntheticSession(item: youtube, start: at(16, 0), minutes: 7)])
        #expect(result.minutes(for: youtube, atLeast: .high) == 5)
        #expect(result.minutes(for: youtube) == 7)
        #expect(result.totals[youtube]?.lowerMinutes == 5)
        #expect(result.totals[youtube]?.upperMinutes == 9)
        #expect(result.unexplainedMinutes == 0)
    }

    @Test func untrackedUseIsUnexplained() {
        let result = timeline([
            SyntheticSession(item: nil, start: at(12, 0), minutes: 3),
            SyntheticSession(item: youtube, start: at(16, 0), minutes: 10),
        ])
        #expect(result.unexplainedMinutes == 3)
        #expect(result.segments.first?.owner == .unexplained)
    }

    @Test func fastSwitchingKeepsTotalsAndMarksMixed() {
        let kid = Kid(displayName: "Test")
        let trace = SyntheticScenario.fastSwitching.trace(kid: kid, day: testDay, calendar: utc)
        let result = Reconstructor.build(DayInput(fires: trace.fires(calendar: utc), dayStart: dayStart))
        let ids = Dictionary(uniqueKeysWithValues: trace.items.map { ($0.nickname!, $0.id) })
        #expect(result.totals[ids["YouTube"]!]?.lowerMinutes == 20)
        #expect(result.totals[ids["Messages"]!]?.lowerMinutes == 10)
        #expect(result.totals[ids["TikTok"]!]?.lowerMinutes == 30)
        #expect(result.totalMinutes == 60)
        #expect(result.segments.contains { if case .mixed = $0.owner { true } else { false } })
        #expect(result.unfulfilledMinutes == 0)
    }

    @Test func catchUpBurstIsSpreadAndLowConfidence() {
        let kid = Kid(displayName: "Test")
        let trace = SyntheticScenario.catchUpBurst.trace(kid: kid, day: testDay, calendar: utc)
        let result = Reconstructor.build(DayInput(fires: trace.fires(calendar: utc), dayStart: dayStart))
        let minecraft = trace.items.first { $0.nickname == "Minecraft" }!.id
        let youtube = trace.items.first { $0.nickname == "YouTube" }!.id
        #expect(result.totalMinutes == 110)
        #expect(result.totals[minecraft]?.lowerMinutes == 90)
        #expect(result.minutes(for: minecraft) == 90)
        #expect(result.segments(for: minecraft).contains { $0.confidence == .low })
        // No in-use minute is squeezed to nothing.
        #expect(result.inUse.allSatisfy { $0.end.timeIntervalSince($0.start) >= 59 })
        // The injected 60-minutes-at-00:01 YouTube fire is impossible and dropped.
        #expect(result.totals[youtube] == nil)
        #expect(result.suspectFires == 1)
    }

    @Test func plausibleEarlyFireIsUnfulfilled() {
        let options = SyntheticOptions(injected: [SyntheticFire(item: tiktok, minute: 60, at: at(8, 0))])
        let result = timeline([SyntheticSession(item: youtube, start: at(16, 0), minutes: 10)], options: options)
        #expect(result.unfulfilledMinutes == 60)
        #expect(result.minutes(for: youtube) == 10)
    }

    @Test func duplicateAndOutOfOrderFires() {
        let input = DayInput(dayStart: dayStart, total: [
            FirePoint(minute: 1, at: at(10, 1)),
            FirePoint(minute: 1, at: at(10, 1, 2)),
            FirePoint(minute: 2, at: at(10, 2)),
            FirePoint(minute: 1, at: at(10, 3)),
        ], items: [:])
        let result = Reconstructor.build(input)
        #expect(result.totalMinutes == 2)
        #expect(result.inUse.count == 2)
        #expect(result.suspectFires == 0)
    }

    /// What the iPhone did on registration: today's 143 total thresholds delivered at once in random order,
    /// then replayed again by a second registration, throttled to ~2 per second.
    @Test func unorderedCatchUpBurstsAreNotSuspect() {
        var points = (1...143).shuffled().enumerated().map { index, minute in
            FirePoint(minute: minute, at: at(17, 39, 41.9 + Double(index) * 0.004))
        }
        points += (1...143).shuffled().enumerated().map { index, minute in
            FirePoint(minute: minute, at: at(17, 41, 52 + Double(index) * 0.5))
        }
        points.append(FirePoint(minute: 144, at: at(17, 45)))
        let result = Reconstructor.build(DayInput(dayStart: dayStart, total: points, items: [:]))
        #expect(result.totalMinutes == 144)
        #expect(result.suspectFires == 0)
        #expect(result.inUse.count == 144)
        #expect(result.inUse.filter(\.inferred).count == 143)
    }

    @Test func liveStatus() {
        let entries = SyntheticTrace.entries(sessions: [SyntheticSession(item: youtube, start: at(16, 0), minutes: 30)])
        let input = DayInput(entries: entries, dayStart: dayStart)
        let result = Reconstructor.build(input)
        let live = LiveStatus.compute(result, input: input, now: at(16, 30, 30))
        #expect(live == LiveStatus(inUse: true, probableItem: youtube, lastActiveAt: at(16, 30)))
        let later = LiveStatus.compute(result, input: input, now: at(17, 0))
        #expect(later == LiveStatus(inUse: false, probableItem: nil, lastActiveAt: at(16, 30)))
        let earlier = LiveStatus.compute(result, input: input, now: at(12, 0))
        #expect(!earlier.inUse)
    }
}
