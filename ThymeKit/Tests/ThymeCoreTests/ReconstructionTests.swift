import Foundation
import Testing
@testable import ThymeCore

struct ReconstructionTests {
    let youtube = UUID(), roblox = UUID()

    @Test func exactTotalsAndOneBlockPerSession() {
        let (_, result) = timeline([SyntheticSession(item: youtube, start: at(16, 0), minutes: 30)])
        #expect(result.totalMinutes == 30)
        #expect(result.items[youtube]?.minutes == 30)
        #expect(result.appMinutes == 30)
        let blocks = result.blocks.filter { $0.itemID == youtube }
        #expect(blocks.count == 1)
        #expect(blocks.first?.start == at(16, 0) && blocks.first?.end == at(16, 30))
        #expect(blocks.first?.intensity == 1)
        #expect(result.inUse.allSatisfy { !$0.inferred })
    }

    @Test func sequentialAppsSplitAtTheWake() {
        let (_, result) = timeline([
            SyntheticSession(item: youtube, start: at(16, 0), minutes: 20),
            SyntheticSession(item: roblox, start: at(16, 20), minutes: 15),
        ])
        #expect(result.items[youtube]?.minutes == 20)
        #expect(result.items[roblox]?.minutes == 14)  // the last odd minute is still pending: no wake yet
        #expect(result.blocks.first { $0.itemID == roblox }?.start == at(16, 20))
        #expect(result.runs.count == 1)
    }

    @Test func separateSessionsAreSeparateBlocks() {
        let (_, result) = timeline([
            SyntheticSession(item: youtube, start: at(9, 0), minutes: 10),
            SyntheticSession(item: youtube, start: at(15, 0), minutes: 10),
        ])
        #expect(result.runs.count == 2)
        #expect(result.blocks.filter { $0.itemID == youtube }.count == 2)
        #expect(result.items[youtube]?.minutes == 20)
    }

    @Test func useAfterIdleIsPlacedWhenThePhoneWasInUse() {
        // Roblox's first sample covers 9:10 (the previous wake) to 9:42; the phone was idle until 9:40.
        let (input, result) = timeline([
            SyntheticSession(item: youtube, start: at(9, 0), minutes: 10),
            SyntheticSession(item: roblox, start: at(9, 40), minutes: 4),
        ])
        #expect(input.samples.contains { $0.itemID == roblox && $0.start == at(9, 10) })
        let blox = result.blocks.filter { $0.itemID == roblox }
        #expect(blox.count == 1)
        #expect(blox.first?.start == at(9, 40) && blox.first?.end == at(9, 44))
        #expect(blox.first?.intensity == 1 && blox.first?.somewhereIn == nil)
    }

    @Test func useTheInUseMinutesMissIsDrawnAtItsLengthAndMarked() {
        // 30 s at 15:05 never reached a wake; the 16:00 hour's fetch reports it for 15:00–16:00.
        let sample = UsageSample(id: UUID(), kidID: testKid.id, itemID: youtube, day: testDay,
                                 start: at(15, 0), end: at(16, 0), seconds: 30)
        let result = Reconstructor.build(DayInput(dayStart: dayStart, total: [], samples: [sample]))
        let block = result.blocks.first
        #expect(block?.start == at(15, 59, 30) && block?.end == at(16, 0))
        #expect(block?.somewhereIn == DateInterval(start: at(15, 0), end: at(16, 0)))
        #expect(result.items[youtube]?.seconds == 30)
    }

    @Test func useBeyondTheInUseMinutesGoesJustBeforeThem() {
        // Two minutes in use at 15:40–15:42, but Apple counts five: three happened before tracking caught them.
        let sample = UsageSample(id: UUID(), kidID: testKid.id, itemID: youtube, day: testDay,
                                 start: at(15, 0), end: at(15, 42), seconds: 300)
        let result = Reconstructor.build(DayInput(dayStart: dayStart, total: [FirePoint(minute: 1, at: at(15, 41)),
                                                                               FirePoint(minute: 2, at: at(15, 42))],
                                                  samples: [sample]))
        let blocks = result.blocks.sorted { $0.start < $1.start }
        #expect(blocks.map(\.start) == [at(15, 37), at(15, 40)])
        #expect(blocks.map(\.seconds) == [180, 120])
        #expect(blocks.first?.somewhereIn != nil && blocks.last?.somewhereIn == nil)
    }

    @Test func fastSwitchingKeepsExactTotals() {
        let trace = SyntheticScenario.fastSwitching.trace(kid: testKid, day: testDay, calendar: utc)
        let result = Reconstructor.build(DayInput(fires: trace.fires(calendar: utc), samples: trace.samples, dayStart: dayStart))
        let ids = Dictionary(uniqueKeysWithValues: trace.items.map { ($0.name!, $0.id) })
        #expect(result.items[ids["YouTube"]!]?.minutes == 20)
        #expect(result.items[ids["Messages"]!]?.minutes == 10)
        #expect(result.items[ids["TikTok"]!]?.minutes == 30)
        // Several apps per 2-minute wake: partial intensity.
        #expect(result.blocks.contains { $0.intensity < 1 })
    }

    @Test func catchUpBurstIsBeforeTrackingAndMisfireDropped() {
        // A registration at 14:20; iOS holds total fires until 15:00, then replays them.
        let options = SyntheticOptions(catchUp: [DateInterval(start: at(14, 20), end: at(15, 0))],
                                       injected: [FirePoint(minute: 60, at: at(0, 1))])
        let (entries, samples) = SyntheticTrace.generate(kid: testKid.id, sessions: [
            SyntheticSession(item: youtube, start: at(14, 0), minutes: 90),
        ], options: options, calendar: utc)
        let input = DayInput(dayStart: dayStart,
                             total: DayInput(entries: entries, samples: [], dayStart: dayStart).total,
                             samples: samples, trackingStarts: [at(14, 50)])
        let result = Reconstructor.build(input)
        // Held minutes 20–60 arrive at 15:00, 10 min after the registration: 10 are real, 32 before tracking.
        #expect(result.preTrackingMinutes == 32)
        #expect(result.suspectFires == 1)
        #expect(result.items[youtube]?.minutes == 90)
    }

    @Test func unorderedCatchUpIsNotSuspect() {
        var points = (1...143).shuffled().enumerated().map { index, minute in
            FirePoint(minute: minute, at: at(17, 39, 41.9 + Double(index) * 0.004))
        }
        points.append(FirePoint(minute: 144, at: at(17, 45)))
        let result = Reconstructor.build(DayInput(dayStart: dayStart, total: points, trackingStarts: [at(17, 39)]))
        #expect(result.totalMinutes == 144)
        #expect(result.suspectFires == 0)
        // The minute that fits in the 42 s since registration counts as real.
        #expect(result.preTrackingMinutes == 142)
        #expect(result.inUse.count == 2)
    }

    @Test func liveStatus() {
        let (input, result) = timeline([SyntheticSession(item: youtube, start: at(16, 0), minutes: 30)])
        #expect(LiveStatus.compute(result, input: input, now: at(16, 31)) ==
            LiveStatus(inUse: true, probableItem: youtube, lastActiveAt: at(16, 30)))
        #expect(LiveStatus.compute(result, input: input, now: at(17, 0)) ==
            LiveStatus(inUse: false, probableItem: nil, lastActiveAt: at(16, 30)))
        #expect(!LiveStatus.compute(result, input: input, now: at(12, 0)).inUse)
    }

    @Test func legacyItemFiresAreIgnored() {
        let fires = [
            UsageFire(id: UUID(), kidID: testKid.id, itemID: nil, minute: 1, firedAt: at(9, 1), day: testDay, epochID: nil),
            UsageFire(id: UUID(), kidID: testKid.id, itemID: youtube, minute: 25, firedAt: at(9, 2), day: testDay, epochID: nil),
        ]
        let result = Reconstructor.build(DayInput(fires: fires, samples: [], dayStart: dayStart))
        #expect(result.totalMinutes == 1)
    }

    @Test func displayNames() {
        let kid = UUID()
        #expect(TrackedItem(kidID: kid, kind: .app, identifier: "com.burbn.instagram", firstSeen: dayStart).displayName == "instagram")
        #expect(TrackedItem(kidID: kid, kind: .domain, identifier: "www.youtube.com", firstSeen: dayStart).displayName == "youtube.com")
        #expect(TrackedItem(kidID: kid, kind: .app, identifier: "x", name: "X App", firstSeen: dayStart).displayName == "X App")
        #expect(TrackedItem.id(kid: kid, kind: .app, identifier: "a") == TrackedItem.id(kid: kid, kind: .app, identifier: "a"))
    }
}
