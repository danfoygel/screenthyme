import Foundation
import Testing
@testable import ThymeCore

struct LadderSpecTests {
    @Test func standardShape() {
        let spec = LadderSpec.standard
        #expect(spec.itemMinutes.count == 56)
        #expect(spec.itemMinutes.prefix(3) == [5, 10, 15])
        #expect(spec.itemMinutes.contains(60) && spec.itemMinutes.contains(75) && !spec.itemMinutes.contains(65))
        #expect(spec.itemMinutes.last == 720)
        #expect(spec.totalMinutes.count == 960)
    }

    @Test func remainders() {
        let spec = LadderSpec.standard
        #expect(spec.itemRemainder(after: 0) == 4)
        #expect(spec.itemRemainder(after: 25) == 4)
        #expect(spec.itemRemainder(after: 60) == 14)
        #expect(spec.itemRemainder(after: 720) == 0)
        #expect(spec.snapItemThreshold(37) == 40)
        #expect(spec.snapItemThreshold(61) == 75)
    }
}

struct EventNameTests {
    @Test func roundTrip() {
        let id = UUID()
        #expect(EventName.parse(EventName.item(id, minute: 45)) == EventName.Parsed(itemID: id, minute: 45))
        #expect(EventName.parse(EventName.total(minute: 7)) == EventName.Parsed(itemID: nil, minute: 7))
        #expect(EventName.parse("x.1") == nil)
        #expect(EventName.parse("i.not-a-uuid.5") == nil)
    }

    @Test func remap() {
        let old = UUID(), new = UUID()
        #expect(EventName.remap(EventName.item(old, minute: 5), items: [old: new]) == EventName.item(new, minute: 5))
        #expect(EventName.remap("t.3", items: [old: new]) == "t.3")
    }
}

struct RollingLadderTests {
    let ladder = RollingLadder()

    @Test func nextItemThresholds() {
        #expect(ladder.itemThresholds(after: 0, short: false) == [5, 10])
        #expect(ladder.itemThresholds(after: 55, short: false) == [60, 75])
        #expect(ladder.itemThresholds(after: 705, short: false) == [720])
        #expect(ladder.itemThresholds(after: 720, short: false).isEmpty)
        #expect(ladder.itemThresholds(after: 55, short: true) == [60])
        #expect(ladder.itemThresholds(after: 60, short: true).isEmpty)
    }

    @Test func totalWindowAndRefill() {
        #expect(ladder.totalThresholds(after: 0) == Array(1...20))
        #expect(ladder.totalThresholds(after: 950) == Array(951...960))
        #expect(!ladder.totalNeedsRefill(crossed: 5, registeredUpTo: 20))
        #expect(ladder.totalNeedsRefill(crossed: 11, registeredUpTo: 20))
    }

    @Test func activitiesSpreadItemsEvenly() {
        let epoch = UUID()
        let items = (0..<180).map { _ in UUID() }
        let activities = RollingLadder.itemActivities(epochID: epoch, itemIDs: items)
        #expect(activities.count == 18)  // 10 per activity
        #expect(activities.allSatisfy { $0.itemIDs.count <= 10 })
        #expect(activities.flatMap(\.itemIDs) == items)
        #expect(activities.allSatisfy { $0.name.hasPrefix(RollingLadder.prefix(for: epoch)) })
        #expect(RollingLadder.itemActivities(epochID: epoch, itemIDs: (0..<532).map { _ in UUID() }).count == 19)
        #expect(RollingLadder.itemActivities(epochID: epoch, itemIDs: [UUID()]).count == 1)
        #expect(!RollingLadder.totalActivity(epochID: epoch).hasSuffix(".total"))
    }

    /// A day of rolling registrations stays tiny: ~2 events per item plus 20, versus 56 per item before.
    @Test func registeredEventCountIsSmall() {
        let items = 180
        #expect(items * ladder.itemLookahead + ladder.totalLookahead == 380)
    }
}

struct MonitorDayStateTests {
    @Test func recordsAndResetsDaily() {
        var state = MonitorDayState(day: testDay)
        let id = UUID()
        state.record(.init(itemID: nil, minute: 3), at: at(10, 0), calendar: utc)
        state.record(.init(itemID: id, minute: 5), at: at(10, 0, 1), calendar: utc)
        state.record(.init(itemID: id, minute: 5), at: at(10, 0, 2), calendar: utc)
        #expect(state.totalMinute == 3 && state.itemMinutes[id] == 5)
        state.record(.init(itemID: nil, minute: 1), at: at(24, 1), calendar: utc)
        #expect(state.day == testDay.adding(days: 1, calendar: utc))
        #expect(state.totalMinute == 1 && state.itemMinutes.isEmpty)
    }
}
