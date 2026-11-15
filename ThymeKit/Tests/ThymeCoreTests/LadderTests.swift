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

struct LadderPlannerTests {
    @Test func splitsItemsUnderCap() throws {
        let planner = LadderPlanner(maxEventsPerActivity: 1000)
        let items = (0..<100).map { _ in UUID() }
        let plan = try planner.plan(epochID: UUID(), itemIDs: items)
        // 1000 / 56 = 17 items per activity → 6 item activities + 1 total.
        #expect(plan.activities.count == 7)
        #expect(!plan.isShortened)
        #expect(plan.activities[0].includesTotal && plan.activities[0].itemIDs.isEmpty)
        #expect(plan.activities.dropFirst().allSatisfy { $0.eventCount(spec: plan.spec) <= 1000 })
        #expect(Set(plan.activities.flatMap(\.itemIDs)) == Set(items))
    }

    @Test func namesShareEpochPrefix() throws {
        let epoch = UUID()
        let plan = try LadderPlanner().plan(epochID: epoch, itemIDs: [UUID()])
        #expect(plan.activities.allSatisfy { $0.name.hasPrefix(LadderPlanner.prefix(for: epoch)) })
    }

    @Test func shortensLadderToFitManyItems() throws {
        let planner = LadderPlanner(maxEventsPerActivity: 1000)
        let items = (0..<400).map { _ in UUID() }
        let plan = try planner.plan(epochID: UUID(), itemIDs: items)
        // 19 item activities; 400 items need ≥ 22 per activity → at most 45 steps.
        #expect(plan.isShortened)
        #expect(plan.spec.itemMinutes.count == 45)
        #expect(plan.spec.itemMinutes.prefix(12) == LadderSpec.standard.itemMinutes.prefix(12))
        #expect(plan.activities.count <= 20)
        #expect(plan.activities.allSatisfy { $0.eventCount(spec: plan.spec) <= 1000 })
        #expect(Set(plan.activities.flatMap(\.itemIDs)) == Set(items))
    }

    @Test func refusesWhenEvenShortestLadderDoesNotFit() {
        let planner = LadderPlanner(maxEventsPerActivity: 1000)
        let items = (0..<2000).map { _ in UUID() }
        // 1000 / 12 = 83 per activity × 19 = 1577.
        #expect(throws: LadderPlanError.tooManyItems(items: 2000, capacity: 1577)) {
            try planner.plan(epochID: UUID(), itemIDs: items)
        }
    }

    @Test func leavesRoomForOldEpoch() throws {
        let planner = LadderPlanner(maxEventsPerActivity: 1000)
        let plan = try planner.plan(epochID: UUID(), itemIDs: (0..<100).map { _ in UUID() }, inUse: 10)
        #expect(plan.activities.count <= 10)
        #expect(throws: LadderPlanError.noActivitiesFree(available: 1)) {
            try planner.plan(epochID: UUID(), itemIDs: [], inUse: 19)
        }
    }

    @Test func refusesCapBelowTotalLadder() {
        #expect(throws: LadderPlanError.ladderLongerThanCap(events: 960, cap: 500)) {
            try LadderPlanner(maxEventsPerActivity: 500).plan(epochID: UUID(), itemIDs: [])
        }
    }
}
