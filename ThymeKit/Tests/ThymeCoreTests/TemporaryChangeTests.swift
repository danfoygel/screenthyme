import Foundation
import Testing
@testable import ThymeCore

struct TemporaryChangeTests {
    let kid = testKid.id
    let roblox = UUID(), youtube = UUID(), games = UUID()
    let limit = AppLimit(name: "Games", items: [UUID()], minutes: 60)
    let bedtime = DowntimeWindow(name: "Bedtime", startMinute: 21 * 60, endMinute: 7 * 60)

    /// `policy` with `change` saved for `days` days at `now`, as a parent's phone saves it.
    func saving(_ change: (inout Policy) -> Void, to policy: Policy, days: Int, now: Date, id: UUID = UUID()) -> Policy {
        var after = policy.current(at: now)
        change(&after)
        after.updatedAt = now
        after.temporary.append(TemporaryChange(id: id, until: TemporaryChange.until(days: days, from: now, calendar: utc),
                                               before: policy.current(at: now), after: after))
        return after
    }

    @Test func endsAtMidnightAfterTheLastDay() {
        #expect(TemporaryChange.until(days: 1, from: at(15, 0), calendar: utc) == at(24, 0))
        #expect(TemporaryChange.until(days: 3, from: at(0, 0), calendar: utc) == at(72, 0))
        #expect(TemporaryChange.until(days: 0, from: at(23, 0), calendar: utc) == at(24, 0))
    }

    @Test func changesBackAtItsEnd() {
        let base = Policy(kidID: kid, limits: [limit], blocked: [roblox])
        let policy = saving({ $0.limits[0].minutes = 120; $0.blocked = [] }, to: base, days: 2, now: at(10, 0))
        #expect(policy.current(at: at(47, 59)).limits[0].minutes == 120)
        let back = policy.current(at: at(48, 0))
        #expect(back.limits == base.limits)
        #expect(back.blocked == [roblox])
        #expect(back.temporary.isEmpty)
    }

    @Test func keepsWhatALaterSaveChanged() {
        let base = Policy(kidID: kid, downtime: [bedtime], limits: [limit])
        var policy = saving({ $0.limits[0].minutes = 120; $0.downtime[0].endMinute = 8 * 60 }, to: base, days: 1, now: at(9, 0))
        // A permanent save after it: the limit's minutes, and a new item in Always Allowed.
        policy.limits[0].minutes = 90
        policy.limits[0].name = "Fun"
        policy.alwaysAllowed.insert(youtube)
        let back = policy.current(at: at(24, 0))
        #expect(back.limits[0].minutes == 90)
        #expect(back.limits[0].name == "Fun")
        #expect(back.downtime[0].endMinute == 7 * 60)
        #expect(back.alwaysAllowed == [youtube])
    }

    @Test func addedAndRemovedElementsAndItemsChangeBack() {
        let other = DowntimeWindow(name: "School", startMinute: 8 * 60, endMinute: 15 * 60)
        let base = Policy(kidID: kid, downtime: [bedtime, other], alwaysAllowed: [roblox])
        let added = AppLimit(name: "YouTube", items: [youtube], minutes: 30)
        let policy = saving({
            $0.downtime.removeAll { $0.id == bedtime.id }
            $0.limits.append(added)
            $0.alwaysAllowed = [games]
        }, to: base, days: 1, now: at(12, 0))
        let back = policy.current(at: at(24, 0))
        #expect(back.downtime == [bedtime, other])
        #expect(back.limits.isEmpty)
        #expect(back.alwaysAllowed == [roblox])
    }

    @Test func restrictionsChangeBackOneByOne() {
        var base = Policy(kidID: kid)
        base.restrictions.webFilter = .allowedOnly(["pbskids.org"])
        var policy = saving({
            $0.restrictions.denySiri = true
            $0.restrictions.webFilter = .unrestricted
            $0.restrictions.maximumAppRating = 300
        }, to: base, days: 1, now: at(12, 0))
        policy.restrictions.denySiri = false
        policy.restrictions.lockESIM = true
        let back = policy.current(at: at(24, 0)).restrictions
        #expect(back.webFilter == .allowedOnly(["pbskids.org"]))
        #expect(back.maximumAppRating == nil)
        #expect(back.lockESIM)
        #expect(!back.denySiri)
    }

    @Test func stackedChangesUnwind() {
        let base = Policy(kidID: kid, limits: [limit])
        let first = saving({ $0.limits[0].minutes = 90 }, to: base, days: 3, now: at(9, 0))
        let second = saving({ $0.limits[0].minutes = 120 }, to: first, days: 1, now: at(10, 0))
        #expect(second.temporary.count == 2)
        #expect(second.current(at: at(24, 0)).limits[0].minutes == 90)
        #expect(second.current(at: at(72, 0)).limits[0].minutes == 60)
        // Ending together, the later save changes back first.
        let together = saving({ $0.limits[0].minutes = 120 }, to: first, days: 3, now: at(10, 0))
        let steps = together.reverts(through: at(72, 0))
        #expect(steps.map { $0.after.limits[0].minutes } == [90, 60])
    }

    @Test func spentChangesAreDropped() {
        var policy = saving({ $0.limits[0].minutes = 120 }, to: Policy(kidID: kid, limits: [limit]), days: 2, now: at(9, 0))
        policy.limits[0].minutes = 45
        policy.dropSpentTemporaryChanges()
        #expect(policy.temporary.isEmpty)
    }

    @Test func temporaryChangesFollowNewTokens() {
        let apple = TrackedItem(kidID: kid, kind: .app, identifier: "com.roblox.robloxmobile", firstSeen: dayStart)
        var stale = TrackedItem(kidID: kid, kind: .app, identifier: TrackedItem.scannedPrefix + "old", firstSeen: dayStart)
        stale.match = apple.id
        var fresh = TrackedItem(kidID: kid, kind: .app, identifier: TrackedItem.scannedPrefix + "new", tokenData: Data([1]),
                                firstSeen: dayStart)
        fresh.match = apple.id
        let items = [apple.id: apple, stale.id: stale, fresh.id: fresh]
        let policy = saving({ $0.blocked.insert(stale.id) }, to: Policy(kidID: kid), days: 1, now: at(9, 0))
            .followingNewTokens(items: items)
        #expect(policy.blocked == [fresh.id])
        #expect(policy.current(at: at(24, 0)).blocked.isEmpty)
    }

    @Test func historyShowsEachChangeBack() {
        let base = Policy(kidID: kid, updatedAt: at(8, 0), limits: [limit])
        let id = UUID()
        let saved = saving({ $0.limits[0].minutes = 120 }, to: base, days: 2, now: at(9, 0), id: id)
        let change = PolicyChange(id: id, kidID: kid, at: at(9, 0), by: "Mom", before: base, after: saved, until: at(48, 0))
        let reverts = PolicyRevert.all(changes: [change], current: saved)
        #expect(reverts.count == 1)
        #expect(reverts[0].at == at(48, 0))
        #expect(reverts[0].edits.count == 1)
        #expect(PolicyChange.policy(at: at(48, 0), changes: [change], current: saved)?.limits[0].minutes == 60)

        // A later permanent save of the same limit leaves nothing to change back.
        var later = saved
        later.limits[0].minutes = 30
        later.updatedAt = at(20, 0)
        later.dropSpentTemporaryChanges()
        let permanent = PolicyChange(kidID: kid, at: at(20, 0), by: "Dad", before: saved, after: later)
        #expect(PolicyRevert.all(changes: [change, permanent], current: later).isEmpty)
    }

    @Test func roundTripsThroughJSON() throws {
        let policy = saving({ $0.blocked = [roblox] }, to: Policy(kidID: kid, updatedAt: dayStart), days: 1, now: at(9, 0))
        let decoded = try JSONDecoder.thyme.decode(Policy.self, from: JSONEncoder.thyme.encode(policy))
        #expect(decoded == policy)
        let change = PolicyChange(kidID: kid, at: at(9, 0), by: "Mom", before: nil, after: policy, until: at(24, 0))
        #expect(try JSONDecoder.thyme.decode(PolicyChange.self, from: JSONEncoder.thyme.encode(change)) == change)
    }
}
