import Foundation
import Testing
@testable import ThymeCore

struct CalendarLayoutTests {
    let youtube = UUID(), roblox = UUID(), messages = UUID()

    func block(_ item: UUID, _ start: Date, _ end: Date) -> UsageBlock {
        UsageBlock(itemID: item, start: start, end: end, seconds: end.timeIntervalSince(start))
    }

    func pieces(_ placed: [CalendarPiece], _ item: UUID) -> [CalendarPiece] {
        placed.filter { $0.block.itemID == item }.sorted { $0.start < $1.start }
    }

    @Test func oneAppAtATimeFillsTheWidth() {
        let placed = CalendarLayout.place([block(youtube, at(16, 0), at(16, 30)), block(roblox, at(16, 30), at(17, 0))])
        #expect(placed.count == 2)
        #expect(placed.allSatisfy { $0.column == 0 && $0.columns == 1 && $0.isLabeled })
    }

    @Test func concurrentAppsSitSideBySideOnlyWhileConcurrent() {
        let placed = CalendarLayout.place([
            block(roblox, at(16, 10), at(16, 20)),
            block(youtube, at(16, 0), at(16, 30)),
        ])
        let tube = pieces(placed, youtube)
        #expect(tube.map(\.start) == [at(16, 0), at(16, 10), at(16, 20)])
        #expect(tube.map(\.columns) == [1, 2, 1])
        #expect(tube.allSatisfy { $0.column == 0 })
        let blox = pieces(placed, roblox)
        #expect(blox.count == 1 && blox.first?.column == 1 && blox.first?.columns == 2)
    }

    @Test func aSwitchSharedByOneFetchIsASliver() {
        // Both apps were used in the 15:59–16:01 fetch.
        let placed = CalendarLayout.place([
            block(roblox, at(15, 30), at(16, 1)),
            block(youtube, at(15, 59), at(16, 45)),
        ])
        #expect(placed.filter { $0.columns == 2 }.allSatisfy { $0.start == at(15, 59) && $0.end == at(16, 1) })
        // Each name goes on the block's full-width stretch.
        #expect(pieces(placed, youtube).first { $0.isLabeled }?.start == at(16, 1))
        #expect(pieces(placed, roblox).first { $0.isLabeled }?.end == at(15, 59))
    }

    @Test func appsKeepTheOrderTheyStartedIn() {
        let placed = CalendarLayout.place([
            block(youtube, at(16, 0), at(17, 0)),
            block(roblox, at(16, 10), at(16, 20)),
            block(messages, at(16, 15), at(16, 30)),
        ])
        #expect(pieces(placed, youtube).allSatisfy { $0.column == 0 })
        #expect(pieces(placed, roblox).allSatisfy { $0.column == 1 })
        #expect(pieces(placed, messages).map(\.column) == [2, 1])
        #expect(placed.filter { $0.isLabeled }.count == 3)
    }

    @Test func fastSwitchingDayHasSideBySidePieces() {
        let trace = SyntheticScenario.fastSwitching.trace(kid: testKid, day: testDay, calendar: utc)
        let result = Reconstructor.build(DayInput(fires: trace.fires(calendar: utc), samples: trace.samples, dayStart: dayStart))
        let placed = CalendarLayout.place(result.blocks)
        #expect(placed.contains { $0.columns > 1 })
        #expect(placed.filter { $0.isLabeled }.count == result.blocks.count)
        // Every block is covered by its pieces, end to end.
        for block in result.blocks {
            let own = placed.filter { $0.block == block }.sorted { $0.start < $1.start }
            #expect(own.first?.start == block.start && own.last?.end == block.end)
            #expect(zip(own, own.dropFirst()).allSatisfy { $0.end == $1.start })
        }
        // No two pieces share a column at the same time.
        for a in placed {
            for b in placed where a.id != b.id && a.start < b.end && b.start < a.end {
                #expect(a.column != b.column)
            }
        }
    }
}

struct CalendarJoinTests {
    let youtube = UUID(), roblox = UUID(), messages = UUID()

    func block(_ item: UUID, _ start: Date, _ end: Date, _ seconds: Double? = nil, guessed: Bool = false) -> UsageBlock {
        UsageBlock(itemID: item, start: start, end: end, seconds: seconds ?? end.timeIntervalSince(start),
                   somewhereIn: guessed ? DateInterval(start: at(9, 0), end: at(10, 0)) : nil)
    }

    @Test func aShortPauseJoins() {
        let shown = CalendarLayout.visible([block(youtube, at(16, 0), at(16, 10)), block(youtube, at(16, 11), at(16, 20))])
        #expect(shown.count == 1)
        #expect(shown.first?.start == at(16, 0) && shown.first?.end == at(16, 20) && shown.first?.seconds == 1140)
    }

    @Test func aPauseOfTwoMinutesDoesNot() {
        #expect(CalendarLayout.visible([block(youtube, at(16, 0), at(16, 10)), block(youtube, at(16, 12), at(16, 20))]).count == 2)
    }

    @Test func anotherAppShownInThePauseKeepsThemApart() {
        let blocks = [block(youtube, at(16, 0), at(16, 10)), block(roblox, at(16, 10), at(16, 11), 50),
                      block(youtube, at(16, 11), at(16, 20))]
        // Everything shown: Roblox is in the pause.
        #expect(CalendarLayout.visible(blocks).filter { $0.itemID == youtube }.count == 2)
        // Under 2 minutes hidden: Roblox's 50 s isn't shown, so YouTube joins.
        let shown = CalendarLayout.visible(blocks, minimum: 120)
        #expect(shown.count == 1 && shown.first?.itemID == youtube)
    }

    @Test func placedAndGuessedStayApart() {
        let blocks = [block(youtube, at(9, 40), at(9, 50), guessed: true), block(youtube, at(9, 50), at(9, 58))]
        #expect(CalendarLayout.visible(blocks).count == 2)
    }

    @Test func shortBlocksJoinedPastTheMinimumAreShown() {
        let blocks = [block(messages, at(16, 0), at(16, 2), 90), block(messages, at(16, 2, 30), at(16, 4), 80)]
        #expect(CalendarLayout.visible(blocks, minimum: 120).first?.seconds == 170)
    }
}
