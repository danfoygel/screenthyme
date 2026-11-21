import Foundation
import Testing
@testable import ThymeCore

/// A kid's request to always allow an app: approving it changes the policy, and the grant lets nothing through itself.
struct AlwaysAllowRequestTests {
    let kid = testKid.id
    let maps = TrackedItem(kidID: testKid.id, kind: .app, identifier: "com.google.Maps", category: "Navigation",
                           firstSeen: dayStart)
    let games = TrackedItem(kidID: testKid.id, kind: .app, identifier: "com.example.game", category: "Games",
                            firstSeen: dayStart)
    var items: [UUID: TrackedItem] { Dictionary(uniqueKeysWithValues: [maps, games].map { ($0.id, $0) }) }

    func request(_ item: TrackedItem) -> TimeRequest {
        TimeRequest(kidID: kid, itemID: item.id, reason: .alwaysAllow, minutes: nil, at: at(10, 0))
    }

    @Test func approvalAllowsTheAppAndUnblocksIt() {
        let policy = Policy(kidID: kid, blocked: [maps.id, games.id])
        let grant = TimeGrant(request: request(maps), approved: true, minutes: nil, at: at(10, 5), by: "Mom")
        let applied = policy.applying(grant)
        #expect(applied.alwaysAllowed == [maps.id])
        #expect(applied.blocked == [games.id])
        #expect(applied.isAlwaysAllowed(maps.id, items: items))
        #expect(applied.applying(grant) == applied)
    }

    @Test func otherAnswersLeaveThePolicy() {
        let policy = Policy(kidID: kid, blocked: [maps.id])
        let declined = TimeGrant(request: request(maps), approved: false, minutes: nil, at: at(10, 5), by: "Mom")
        #expect(policy.applying(declined) == policy)
        let moreTime = TimeRequest(kidID: kid, itemID: maps.id, reason: .blocked, minutes: 15, at: at(10, 0))
        #expect(policy.applying(TimeGrant(request: moreTime, approved: true, minutes: 15, at: at(10, 5), by: "Mom"))
            == policy)
    }

    @Test func allowedThroughAGroup() {
        let group = ItemGroup(name: "Travel", items: [maps.id])
        let policy = Policy(kidID: kid, alwaysAllowed: [group.id], groups: [group])
        #expect(policy.isAlwaysAllowed(maps.id, items: items))
        #expect(!policy.isAlwaysAllowed(games.id, items: items))
    }

    @Test func grantLetsNothingThrough() {
        let policy = Policy(kidID: kid, downtime: [DowntimeWindow(name: "Night", startMinute: 0, endMinute: 12 * 60)],
                            blocked: [games.id])
        var state = EnforcementDayState(day: testDay)
        let answer = TimeGrant(request: request(games), approved: true, minutes: nil, at: at(10, 5), by: "Mom")
        state.grants = [AppliedGrant(grant: answer, appliedAt: at(10, 5))]
        let before = EnforcementPlanner.plan(policy: policy, items: items, usage: [:],
                                             state: EnforcementDayState(day: testDay), now: at(11, 0), calendar: utc)
        let after = EnforcementPlanner.plan(policy: policy, items: items, usage: [:], state: state, now: at(11, 0),
                                            calendar: utc)
        #expect(after == before)
        #expect(after.blockedItems == [games.id])
        #expect(!after.downtimeExceptions.contains(games.id))
    }

    @Test func requestShowsOnTheAppsDetails() {
        let details = AppDetails(item: maps, items: items, policy: Policy(kidID: kid))
        let asked = request(maps)
        let other = request(games)
        let shown = details.requests([asked, other], grants: [], extraMinutes: [], since: at(0, 0))
        #expect(shown.map(\.id) == [asked.id])
    }
}
