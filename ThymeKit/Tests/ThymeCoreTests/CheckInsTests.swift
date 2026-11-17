import Foundation
import Testing
@testable import ThymeCore

struct CheckInsTests {
    let youtube = UUID(), roblox = UUID(), messages = UUID()

    func sample(_ item: UUID, _ start: Date, _ end: Date, _ seconds: Double, reported: Date? = nil) -> UsageSample {
        UsageSample(id: UUID(), kidID: testKid.id, itemID: item, day: testDay, start: start, end: end, seconds: seconds,
                    reportedAt: reported ?? end)
    }

    func coverage(_ result: DayTimeline, at date: Date) -> Coverage? {
        result.coverage.first { $0.start <= date && date < $0.end }?.coverage
    }

    @Test func regularUseIsPlacedAndIdleIsQuiet() {
        let (_, result) = timeline([SyntheticSession(item: youtube, start: at(16, 0), minutes: 30)])
        #expect(coverage(result, at: at(15, 0)) == .quiet)
        #expect(coverage(result, at: at(16, 1)) == .placed)
        #expect(coverage(result, at: at(16, 29)) == .placed)
        #expect(result.blocks.count == 1 && result.blocks.allSatisfy { $0.somewhereIn == nil })
    }

    @Test func aLittleUseBetweenCheckInsIsDropped() {
        // 16 s of Messages since 9:24, reported at 10:25 for the 9 o'clock hour; no wake in between.
        let result = Reconstructor.build(DayInput(dayStart: dayStart, total: [], samples: [
            sample(messages, at(9, 24), at(10, 0), 16, reported: at(10, 25)),
        ]))
        #expect(result.blocks.isEmpty)
        #expect(coverage(result, at: at(9, 30)) == .quiet)
        #expect(result.items[messages]?.seconds == 16)
    }

    @Test func useWithNoWakeIsBlindAndGuessedBackToBack() {
        // 25 min of use in the 5 o'clock hour, and the wake alarm never fired.
        let result = Reconstructor.build(DayInput(dayStart: dayStart, total: [], samples: [
            sample(youtube, at(17, 0), at(18, 0), 900, reported: at(18, 30)),
            sample(roblox, at(17, 0), at(18, 0), 600, reported: at(18, 30)),
        ]))
        #expect(coverage(result, at: at(17, 30)) == .blind)
        let tube = result.blocks.first { $0.itemID == youtube }
        let blox = result.blocks.first { $0.itemID == roblox }
        // The most-used app last, ending with the sample's window; the other just before it.
        #expect(tube?.start == at(17, 45) && tube?.end == at(18, 0))
        #expect(blox?.start == at(17, 35) && blox?.end == at(17, 45))
        #expect(tube?.somewhereIn == DateInterval(start: at(17, 0), end: at(18, 0)))
    }

    @Test func aBurstLosesItsTiming() {
        // An on-time wake at 9:24, then iOS delivers ten minutes' worth at once at 10:25.
        var total = [FirePoint(minute: 80, at: at(9, 22)), FirePoint(minute: 82, at: at(9, 24))]
        total += stride(from: 84, through: 102, by: 2).enumerated().map { index, minute in
            FirePoint(minute: minute, at: at(10, 25, Double(index) * 3))
        }
        let result = Reconstructor.build(DayInput(dayStart: dayStart, total: total, samples: [
            sample(youtube, at(10, 0), at(10, 25, 27), 180),
        ]))
        #expect(coverage(result, at: at(9, 23)) == .placed)
        #expect(coverage(result, at: at(10, 0)) == .burst)
        let block = result.blocks.first
        #expect(block?.somewhereIn != nil && block?.seconds == 180)
        #expect(block?.end == at(10, 25, 27))
    }

    @Test func extraUseBeforeAnOnTimeWakeIsGuessedBeforeIt() {
        // Two minutes placed by the wake at 15:42, but Apple counts five since the previous fetch at 15:00.
        let result = Reconstructor.build(DayInput(dayStart: dayStart, total: [FirePoint(minute: 2, at: at(15, 42))],
                                                  samples: [sample(youtube, at(15, 0), at(15, 42), 300)]))
        let blocks = result.blocks.sorted { $0.start < $1.start }
        #expect(blocks.map(\.start) == [at(15, 37), at(15, 40)])
        #expect(blocks.map(\.seconds) == [180, 120])
        #expect(blocks.first?.somewhereIn != nil && blocks.last?.somewhereIn == nil)
        #expect(coverage(result, at: at(15, 20)) == .blind)
        #expect(coverage(result, at: at(15, 41)) == .placed)
    }

    @Test func websitesDoNotTipAStretchIntoBlind() {
        var input = DayInput(dayStart: dayStart, total: [], samples: [
            sample(youtube, at(9, 0), at(10, 0), 90, reported: at(10, 5)),
            sample(roblox, at(9, 0), at(10, 0), 90, reported: at(10, 5)),
        ])
        #expect(coverage(Reconstructor.build(input), at: at(9, 30)) == .blind)
        input.websites = [roblox]
        #expect(coverage(Reconstructor.build(input), at: at(9, 30)) == .quiet)
    }
}
