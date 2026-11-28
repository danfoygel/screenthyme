import Foundation
import Testing
@testable import ThymeCore

/// Mandatory breaks (PLAN.md §15.13).
struct BreakTests {
    let kid = testKid.id
    let instagram = TrackedItem(kidID: testKid.id, kind: .app, identifier: "com.burbn.instagram", category: "Social",
                                firstSeen: dayStart)
    let messages = TrackedItem(kidID: testKid.id, kind: .app, identifier: "com.apple.MobileSMS", category: "Social",
                               firstSeen: dayStart)
    var items: [UUID: TrackedItem] { Dictionary(uniqueKeysWithValues: [instagram, messages].map { ($0.id, $0) }) }
    var policy: Policy { Policy(kidID: kid, alwaysAllowed: [messages.id], breaks: BreakRule(useMinutes: 45, breakMinutes: 15)) }

    /// Wakes a minute apart through each stretch of `app`'s use, as the wake alarm gives them: `(start, minutes)` from
    /// noon. Returns the state and when the first break started.
    func use(_ stretches: [(start: Int, minutes: Int)], app: UUID? = nil, policy: Policy? = nil,
             state: EnforcementDayState? = nil) -> (state: EnforcementDayState, breakAt: Date?) {
        var state = state ?? EnforcementDayState(day: testDay)
        var usage: [UUID: Double] = [:]
        var breakAt: Date?
        for stretch in stretches {
            for minute in 1...stretch.minutes {
                usage[app ?? instagram.id, default: 0] += 60
                let now = at(12, stretch.start + minute)
                if EnforcementPlanner.trackBreaks(policy: policy ?? self.policy, items: items, usage: usage,
                                                  state: &state, now: now), breakAt == nil {
                    breakAt = now
                }
            }
        }
        return (state, breakAt)
    }

    func plan(_ state: EnforcementDayState, at date: Date, policy: Policy? = nil) -> EnforcementPlan {
        EnforcementPlanner.plan(policy: policy ?? self.policy, items: items, usage: [:], state: state, now: date,
                                calendar: utc)
    }

    @Test func aShortGapDoesntStartTheCountOver() {
        let (state, breakAt) = use([(0, 44), (54, 2)])
        #expect(breakAt == at(12, 55))
        #expect(state.breaks.breakUntil == at(13, 10))
        let during = plan(state, at: at(13, 0))
        #expect(during.breakTime == DateInterval(start: at(12, 55), end: at(13, 10)))
        #expect(during.breakExceptions == [messages.id])
    }

    @Test func aRestAsLongAsTheBreakStartsTheCountOver() {
        let (state, breakAt) = use([(0, 44), (59, 2)])
        #expect(breakAt == nil)
        #expect(state.breaks.stretchSeconds == 2 * 60)
    }

    @Test func alwaysAllowedUseDoesntCount() {
        let (state, breakAt) = use([(0, 60)], app: messages.id)
        #expect(breakAt == nil)
        #expect(state.breaks.stretchStartSeconds == nil)
    }

    @Test func theBreakEndsOnTheClockAndANewStretchBegins() {
        var (state, _) = use([(0, 45)])
        #expect(plan(state, at: at(12, 59, 59)).breakTime != nil)
        #expect(plan(state, at: at(13, 0)).breakTime == nil)
        // Use after the break counts from its end.
        var usage = [instagram.id: 46 * 60.0]
        #expect(!EnforcementPlanner.trackBreaks(policy: policy, items: items, usage: usage, state: &state, now: at(13, 1)))
        usage[instagram.id]! += 60
        EnforcementPlanner.trackBreaks(policy: policy, items: items, usage: usage, state: &state, now: at(13, 2))
        #expect(state.breaks.breakUntil == nil)
        #expect(state.breaks.stretchSeconds == 2 * 60)
    }

    @Test func aGrantDuringTheBreakLiftsIt() {
        var (state, _) = use([(0, 45)])
        let request = TimeRequest(kidID: kid, itemID: nil, reason: .breakTime, minutes: 5, at: at(12, 48))
        state.grants.append(AppliedGrant(grant: TimeGrant(request: request, approved: true, minutes: 5, at: at(12, 50), by: "Mom"),
                                         appliedAt: at(12, 50)))
        #expect(plan(state, at: at(12, 52)).breakTime == nil)
        #expect(plan(state, at: at(12, 56)).breakTime != nil)

        // One for an app lets only that app through.
        var (other, _) = use([(0, 45)])
        let forApp = TimeRequest(kidID: kid, itemID: instagram.id, reason: .breakTime, minutes: 5, at: at(12, 48))
        other.grants.append(AppliedGrant(grant: TimeGrant(request: forApp, approved: true, minutes: nil, at: at(12, 50), by: "Mom"),
                                         appliedAt: at(12, 50)))
        #expect(plan(other, at: at(12, 52)).breakExceptions == [messages.id, instagram.id])
    }

    @Test func oneMoreMinuteIsOncePerBreak() {
        var (state, _) = use([(0, 45)])
        #expect(state.canTakeExtraMinute(itemID: nil, reason: .breakTime))
        state.extraMinutes.append(ExtraMinute(itemID: nil, reason: .breakTime, at: at(12, 50)))
        #expect(!state.canTakeExtraMinute(itemID: nil, reason: .breakTime))
        #expect(plan(state, at: at(12, 50, 30)).breakTime == nil)
        #expect(plan(state, at: at(12, 51, 30)).breakTime != nil)
        // The next break starts the count again.
        state.breaks.breakStart = at(14, 0)
        state.breaks.breakUntil = at(14, 15)
        #expect(state.canTakeExtraMinute(itemID: nil, reason: .breakTime))
    }

    @Test func aNewDayOrTheRuleOffClearsIt() {
        let (state, _) = use([(0, 45)])
        var tomorrow = state
        tomorrow.day = DayKey(year: 2026, month: 11, day: 13)
        #expect(plan(tomorrow, at: at(12, 50)).breakTime == nil)
        var off = policy
        off.breaks?.enabled = false
        #expect(plan(state, at: at(12, 50), policy: off).breakTime == nil)
        #expect(use([(0, 60)], policy: off).breakAt == nil)
    }

    @Test func breaksSitBesideDowntimeAndLimits() {
        let (state, _) = use([(0, 45)])
        var policy = self.policy
        policy.downtime = [DowntimeWindow(name: "Lunch", startMinute: 12 * 60 + 50, endMinute: 13 * 60 + 30)]
        policy.limits = [AppLimit(name: "Social", items: [instagram.id], minutes: 0)]
        let both = plan(state, at: at(12, 55), policy: policy)
        #expect(both.downtime != nil)
        #expect(both.breakTime != nil)
        #expect(both.exhaustedLimits == Set(policy.limits.map(\.id)))
    }

    @Test func policiesWithoutBreaksStillLoad() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(policy)) as! [String: Any]
        json["breaks"] = nil
        let decoded = try JSONDecoder().decode(Policy.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.breaks == nil)
        let state = try JSONDecoder().decode(EnforcementDayState.self,
                                             from: JSONEncoder().encode(["day": testDay]))
        #expect(state.breaks == BreakTracker())
    }

    @Test func theHistoryNamesBreakChanges() {
        let old = Policy(kidID: kid, alwaysAllowed: [messages.id])
        let edits = PolicyEdit.between(old, policy)
        #expect(edits == [.breaks(from: BreakRule(enabled: false), to: policy.breaks)])
        #expect(edits[0].describe { _ in "" } == ("Turned breaks on", ["15 min after 45 min of use"]))
        var later = policy
        later.breaks?.enabled = false
        #expect(PolicyEdit.between(policy, later)[0].describe { _ in "" }.title == "Turned breaks off")
    }

    /// Each ruleset takes its own breaks: the one in effect's are the policy's for the day, and are saved with it for
    /// older kid builds. `at(0, 0)` is a Saturday.
    @Test func theRulesetInEffectTakesBreaks() {
        var rules = policy.withDefaultRuleSets()
        #expect(rules.ruleSets.allSatisfy { $0.breaks == BreakRule(useMinutes: 45, breakMinutes: 15) })
        rules.editRuleSet(rules.ruleSets[1].id) { $0.breaks.enabled = false }
        #expect(rules.current(at: at(12, 0), calendar: utc).breaks?.enabled == false)   // Weekend
        #expect(rules.current(at: at(2 * 24 + 12, 0), calendar: utc).breaks?.enabled == true)   // Monday
        #expect(rules.saving(at: at(12, 0), calendar: utc).breaks?.enabled == false)
        #expect(rules.ruleSets[1].copy(name: "Trip").breaks.enabled == false)
        // Off on Saturday: a stretch of use brings no break.
        #expect(use([(0, 60)], policy: rules.current(at: at(12, 0), calendar: utc)).breakAt == nil)
    }

    /// Saved when breaks were the policy's, for every ruleset: each ruleset gets them. Saved since, each keeps its own,
    /// off included.
    @Test func breaksSavedForEveryRulesetGoToEachOne() throws {
        var rules = policy.withDefaultRuleSets()
        rules.editRuleSet(rules.ruleSets[1].id) { $0.breaks.enabled = false }
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(rules)) as? [String: Any])
        let encoded = try #require(json["ruleSets"] as? [[String: Any]])
        json["ruleSets"] = encoded.map { var set = $0; set["breaks"] = nil; return set }
        let old = try JSONDecoder().decode(Policy.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.ruleSets.map(\.breaks.enabled) == [true, true, true])
        let new = try JSONDecoder().decode(Policy.self, from: JSONEncoder().encode(rules))
        #expect(new.ruleSets.map(\.breaks.enabled) == [true, false, true])
    }

    @Test func historyAndTemporaryChangesTakeTheRulesetsBreaks() {
        let old = policy.withDefaultRuleSets()
        var new = old
        new.editRuleSet(old.ruleSets[1].id) { $0.breaks.useMinutes = 30 }
        #expect(PolicyEdit.between(old, new).map { $0.describe { _ in "" }.title } == ["Weekend: Changed breaks"])
        let change = TemporaryChange(id: UUID(), until: at(24, 0), before: old, after: new)
        #expect(new.reverting(change).ruleSets.map(\.breaks.useMinutes) == [45, 45, 45])
    }
}
