import Foundation
import Testing
@testable import ThymeCore

struct ItemAliasesTests {
    let phone = TrackedItem(kidID: testKid.id, kind: .app, identifier: BuiltInApps.phone, firstSeen: dayStart)
    let callScreen = TrackedItem(kidID: testKid.id, kind: .app, identifier: BuiltInApps.callScreen, firstSeen: dayStart)
    let game = TrackedItem(kidID: testKid.id, kind: .app, identifier: "com.example.game", firstSeen: dayStart)

    func sample(_ item: TrackedItem, _ start: Date, _ end: Date, _ seconds: Double, reported: Date) -> UsageSample {
        UsageSample(id: UUID(), kidID: testKid.id, itemID: item.id, day: testDay, start: start, end: end, seconds: seconds,
                    reportedAt: reported)
    }

    @Test func theCallScreenIsShownAsPhone() {
        #expect(ItemAliases.build([phone, callScreen, game]) == [callScreen.id: phone.id])
    }

    @Test func withoutPhoneTheCallScreenStaysItself() {
        #expect(ItemAliases.build([callScreen, game]).isEmpty)
    }

    @Test func theCallScreensSecondsJoinPhonesInTheSameFetch() {
        let samples = [
            sample(callScreen, at(17, 0), at(18, 0), 52, reported: at(17, 40)),
            sample(phone, at(17, 0), at(18, 0), 12, reported: at(17, 40)),
            sample(game, at(17, 0), at(18, 0), 300, reported: at(17, 40)),
            // A later fetch with only the call screen.
            sample(callScreen, at(17, 0), at(18, 0), 30, reported: at(17, 50)),
        ]
        let merged = ItemAliases.apply(ItemAliases.build([phone, callScreen, game]), to: samples)
        #expect(merged.count == 3)
        #expect(merged.filter { $0.itemID == phone.id }.map(\.seconds) == [64, 30])
        #expect(!merged.contains { $0.itemID == callScreen.id })
        #expect(merged.reduce(0) { $0 + $1.seconds } == samples.reduce(0) { $0 + $1.seconds })
    }

    @Test func aDayShowsTheCallScreenAsPhone() {
        var input = DayInput(dayStart: dayStart, total: [], samples: [
            sample(callScreen, at(17, 0), at(18, 0), 52, reported: at(18, 30)),
            sample(phone, at(17, 0), at(18, 0), 12, reported: at(18, 30)),
        ])
        input.aliases = ItemAliases.build([phone, callScreen])
        let timeline = Reconstructor.build(input)
        #expect(timeline.items.mapValues(\.seconds) == [phone.id: 64])
        #expect(timeline.attributed.mapValues(\.seconds) == [phone.id: 64])
        #expect(timeline.blocks.allSatisfy { $0.itemID == phone.id })
    }
}
