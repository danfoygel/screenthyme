import Foundation
import Testing
@testable import ThymeCore

struct CalendarLayoutTests {
    let youtube = UUID(), roblox = UUID(), messages = UUID()

    func block(_ item: UUID, _ start: Date, _ end: Date) -> UsageBlock {
        UsageBlock(itemID: item, start: start, end: end, seconds: end.timeIntervalSince(start))
    }

    func piece(_ placed: [CalendarPiece], _ item: UUID, at start: Date) -> CalendarPiece? {
        placed.first { $0.block.itemID == item && $0.block.start == start }
    }

    @Test func oneAppAtATimeFillsTheWidth() {
        let placed = CalendarLayout.place([block(youtube, at(16, 0), at(16, 30)), block(roblox, at(16, 30), at(17, 0))])
        #expect(placed.count == 2)
        #expect(placed.allSatisfy { $0.column == 0 && $0.columns == 1 })
    }

    @Test func overlappingAppsGetSwimLanes() {
        let placed = CalendarLayout.place([
            block(roblox, at(16, 10), at(16, 20)),
            block(youtube, at(16, 0), at(16, 30)),
            block(messages, at(17, 0), at(17, 10)),
        ])
        // Each block is drawn whole: one piece.
        #expect(placed.count == 3)
        #expect(piece(placed, youtube, at: at(16, 0))?.column == 0)
        #expect(piece(placed, roblox, at: at(16, 10))?.column == 1)
        #expect(piece(placed, youtube, at: at(16, 0))?.columns == 2)
        #expect(piece(placed, roblox, at: at(16, 10))?.columns == 2)
        // A block that overlaps nothing is full width.
        #expect(piece(placed, messages, at: at(17, 0))?.columns == 1)
    }

    @Test func anAppKeepsItsLane() {
        // Instagram, then Reddit overlapping it, then Instagram again overlapping Reddit.
        let instagram = youtube, reddit = roblox
        let placed = CalendarLayout.place([
            block(instagram, at(14, 55), at(15, 3)),
            block(reddit, at(15, 1), at(15, 6)),
            block(instagram, at(15, 5), at(15, 10)),
        ])
        #expect(placed.filter { $0.block.itemID == instagram }.allSatisfy { $0.column == 0 })
        #expect(piece(placed, reddit, at: at(15, 1))?.column == 1)
        #expect(placed.allSatisfy { $0.columns == 2 })
    }

    @Test func appsKeepTheOrderTheyStartedIn() {
        let placed = CalendarLayout.place([
            block(youtube, at(16, 0), at(17, 0)),
            block(roblox, at(16, 10), at(16, 20)),
            block(messages, at(16, 15), at(16, 30)),
        ])
        #expect(placed.map(\.column) == [0, 1, 2])
        #expect(placed.allSatisfy { $0.columns == 3 })
    }

    @Test func fastSwitchingDayHasSwimLanes() {
        let trace = SyntheticScenario.fastSwitching.trace(kid: testKid, day: testDay, calendar: utc)
        let result = Reconstructor.build(DayInput(fires: trace.fires(calendar: utc), samples: trace.samples, dayStart: dayStart))
        let placed = CalendarLayout.place(result.blocks)
        #expect(placed.contains { $0.columns > 1 })
        // One piece per block, in a lane that exists.
        #expect(placed.count == result.blocks.filter { $0.end > $0.start }.count)
        #expect(placed.allSatisfy { $0.column < $0.columns })
        // No two overlapping blocks share a lane, and overlapping blocks are drawn the same width.
        for a in placed {
            for b in placed where a.id != b.id && a.block.start < b.block.end && b.block.start < a.block.end {
                #expect(a.column != b.column)
                #expect(a.columns == b.columns)
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
