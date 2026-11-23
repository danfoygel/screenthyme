import Foundation
import Testing
@testable import ThymeCore

struct UncountedTests {
    let kid = testKid.id
    let roblox = TrackedItem(kidID: testKid.id, kind: .app, identifier: "com.roblox.robloxmobile", category: "Games",
                             firstSeen: dayStart)
    let khan = TrackedItem(kidID: testKid.id, kind: .app, identifier: "org.khanacademy.Khan-Academy", category: "Education",
                           firstSeen: dayStart)
    let duolingo = TrackedItem(kidID: testKid.id, kind: .app, identifier: "com.duolingo.DuolingoMobile", category: "Education",
                               firstSeen: dayStart)
    let education = TrackedItem(kidID: testKid.id, kind: .category, identifier: "Education", firstSeen: dayStart)
    /// The scan's Khan Academy, matched to Apple's.
    var scannedKhan: TrackedItem {
        var item = TrackedItem(kidID: kid, kind: .app, identifier: TrackedItem.scannedPrefix + "k", tokenData: Data([1]),
                               firstSeen: dayStart)
        item.match = khan.id
        return item
    }
    var items: [UUID: TrackedItem] {
        Dictionary(uniqueKeysWithValues: [roblox, khan, duolingo, education, scannedKhan].map { ($0.id, $0) })
    }

    func day(total: Int, _ use: [UUID: Double]) -> DayTimeline {
        DayTimeline(inUse: [], coverage: [], runs: [], blocks: [],
                    items: use.mapValues { ItemUsage(seconds: $0, firstAt: at(9, 0), lastAt: at(10, 0)) },
                    totalMinutes: total, preTrackingMinutes: 0, suspectFires: 0, lastTotalFireAt: nil)
    }

    @Test func staysInsideAlwaysAllowed() {
        let other = UUID()
        var policy = Policy(kidID: kid, alwaysAllowed: [scannedKhan.id], uncounted: [scannedKhan.id, other])
        #expect(policy.uncounted == [scannedKhan.id])
        policy.alwaysAllowed.insert(roblox.id)
        #expect(policy.uncounted == [scannedKhan.id])
        policy.alwaysAllowed.remove(scannedKhan.id)
        #expect(policy.uncounted.isEmpty)
        // Added back to Always Allowed, it isn't Uncounted again by itself.
        policy.alwaysAllowed.insert(scannedKhan.id)
        #expect(policy.uncounted.isEmpty)
    }

    @Test func removingAGroupRemovesItFromUncounted() {
        let group = ItemGroup(name: "School", items: [scannedKhan.id])
        var policy = Policy(kidID: kid, alwaysAllowed: [group.id], uncounted: [group.id], groups: [group])
        #expect(policy.resolved.uncounted == [scannedKhan.id])
        policy.removeGroup(group.id)
        #expect(policy.uncounted.isEmpty)
    }

    @Test func decodesOlderPoliciesAndDropsWhatIsntAlwaysAllowed() throws {
        let policy = Policy(kidID: kid, alwaysAllowed: [khan.id], uncounted: [khan.id])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(policy)) as! [String: Any]
        let back = try JSONDecoder().decode(Policy.self, from: JSONEncoder().encode(policy))
        #expect(back.uncounted == [khan.id])
        json["uncounted"] = [khan.id.uuidString, roblox.id.uuidString]
        let extra = try JSONDecoder().decode(Policy.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(extra.uncounted == [khan.id])
        json.removeValue(forKey: "uncounted")
        let older = try JSONDecoder().decode(Policy.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(older.uncounted.isEmpty && older.alwaysAllowed == [khan.id])
    }

    @Test func followsNewTokens() {
        var stale = scannedKhan
        stale.tokenData = nil
        var fresh = TrackedItem(kidID: kid, kind: .app, identifier: TrackedItem.scannedPrefix + "k2", tokenData: Data([9]),
                                firstSeen: dayStart)
        fresh.match = khan.id
        let all = Dictionary(uniqueKeysWithValues: [khan, stale, fresh].map { ($0.id, $0) })
        let policy = Policy(kidID: kid, alwaysAllowed: [stale.id], uncounted: [stale.id]).followingNewTokens(items: all)
        #expect(policy.alwaysAllowed == [fresh.id])
        #expect(policy.uncounted == [fresh.id])
    }

    @Test func dayTotalLeavesOutUncountedApps() {
        let use = [roblox.id: 40 * 60.0, khan.id: 30 * 60.0, duolingo.id: 10 * 60.0]
        let none = DayTotal(day(total: 85, use), items: items, policy: Policy(kidID: kid))
        #expect(none.appMinutes == 80 && none.inUseMinutes == 85 && none.uncountedMinutes == 0 && none.minutes == 85)
        // Through the scan's Khan Academy, matched to Apple's; Always Allowed alone changes nothing.
        let allowed = Policy(kidID: kid, alwaysAllowed: [scannedKhan.id])
        #expect(DayTotal(day(total: 85, use), items: items, policy: allowed).minutes == 85)
        var policy = allowed
        policy.uncounted = [scannedKhan.id]
        let total = DayTotal(day(total: 85, use), items: items, policy: policy)
        #expect(total.uncountedMinutes == 30)
        #expect(total.appMinutes == 50 && total.inUseMinutes == 55 && total.minutes == 55)
        // A category: both its apps.
        let category = Policy(kidID: kid, alwaysAllowed: [education.id], uncounted: [education.id])
        #expect(DayTotal(day(total: 85, use), items: items, policy: category).minutes == 45)
    }

    @Test func dayTotalSkipsMirroredApps() {
        let use = [roblox.id: 40 * 60.0, duolingo.id: 10 * 60.0]
        let policy = Policy(kidID: kid, alwaysAllowed: [education.id], uncounted: [education.id])
        // Duolingo's time was Safari's on its website: it's out of the apps already, and not taken off the ladder.
        let total = DayTotal(day(total: 50, use), items: items, policy: policy, mirrored: [duolingo.id])
        #expect(total.uncountedMinutes == 0 && total.appMinutes == 40 && total.inUseMinutes == 50)
    }

    @Test func phoneWideThresholdLeavesOutUncountedApps() {
        let rule = Rule(kidID: kid, condition: .dailyThreshold(itemID: nil, minutes: 120))
        let wake = WakeObservation(at: at(18, 0), totalMinute: 130,
                                   itemSeconds: [roblox.id: 100 * 60, khan.id: 30 * 60])
        var state = MonitorDayState(day: testDay)
        let counting = RuleEngine(kidID: kid, kidName: "Emma", items: items, calendar: utc)
        #expect(counting.process(wake, state: &state, rules: [rule]).count == 1)

        let policy = Policy(kidID: kid, alwaysAllowed: [scannedKhan.id], uncounted: [scannedKhan.id]).resolved(items: items)
        let engine = RuleEngine(kidID: kid, kidName: "Emma", items: items, policy: policy, calendar: utc)
        state = MonitorDayState(day: testDay)
        #expect(engine.process(wake, state: &state, rules: [rule]).isEmpty)
        let later = WakeObservation(at: at(18, 30), totalMinute: 151, itemSeconds: [roblox.id: 121 * 60, khan.id: 30 * 60])
        let alerts = engine.process(later, state: &state, rules: [rule])
        #expect(alerts.count == 1)
        #expect(alerts.first?.body == "121 min on the phone today.")
        // Khan Academy's own threshold still counts it.
        let own = Rule(kidID: kid, condition: .dailyThreshold(itemID: khan.id, minutes: 30))
        #expect(engine.process(later, state: &state, rules: [own]).count == 1)
    }

    @Test func historyAndTemporaryChanges() {
        let base = Policy(kidID: kid, alwaysAllowed: [khan.id])
        var after = base
        after.uncounted = [khan.id]
        #expect(PolicyEdit.between(base, after) == [.uncounted(added: [khan.id], removed: [])])
        // Saved for today, then taken off Always Allowed for good: midnight brings neither back.
        var policy = after
        policy.temporary = [TemporaryChange(id: UUID(), until: at(24, 0), before: base, after: after)]
        policy.alwaysAllowed.remove(khan.id)
        let back = policy.current(at: at(24, 0))
        #expect(back.alwaysAllowed.isEmpty && back.uncounted.isEmpty)
        // A temporary Uncounted off: back on at midnight, while still Always Allowed.
        var off = after
        off.uncounted = []
        var temporary = off
        temporary.temporary = [TemporaryChange(id: UUID(), until: at(24, 0), before: after, after: off)]
        #expect(temporary.current(at: at(24, 0)).uncounted == [khan.id])
        // The same, taken off Always Allowed meanwhile: it can't come back as Uncounted alone.
        temporary.alwaysAllowed.remove(khan.id)
        #expect(temporary.current(at: at(24, 0)).uncounted.isEmpty)
    }

    @Test func appDetailsShowUncounted() {
        let policy = Policy(kidID: kid, alwaysAllowed: [education.id], uncounted: [education.id])
        let details = AppDetails(item: khan, items: items, policy: policy)
        #expect(details.uncounted == [.category(education.id)])
        #expect(AppDetails(item: roblox, items: items, policy: policy).uncounted.isEmpty)
    }
}
