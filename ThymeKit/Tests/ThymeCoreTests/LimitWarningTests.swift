import Foundation
import Testing
@testable import ThymeCore

struct LimitWarningTests {
    let instagram = TrackedItem(kidID: testKid.id, kind: .app, identifier: "com.burbn.instagram", category: "Social",
                                firstSeen: dayStart)

    func plan(_ limits: [AppLimit], used: Int, budget: Int, exhausted: Bool = false) -> EnforcementPlan {
        var plan = EnforcementPlan()
        for limit in limits {
            plan.used[limit.id] = used
            plan.budgets[limit.id] = budget
            if exhausted { plan.exhaustedLimits.insert(limit.id) }
        }
        return plan
    }

    func due(_ limit: AppLimit, used: Int, budget: Int, percents: [Int], sent: inout [UUID: LimitWarning.Sent])
        -> [LimitWarning] {
        LimitWarning.due(in: plan([limit], used: used, budget: budget), limits: [limit], percents: percents, sent: &sent)
    }

    @Test func warnsOnceAtEachPercentageReached() {
        let limit = AppLimit(name: "Instagram", items: [], minutes: 60)
        var sent: [UUID: LimitWarning.Sent] = [:]
        #expect(due(limit, used: 44, budget: 60, percents: [75, 90], sent: &sent).isEmpty)
        let first = due(limit, used: 45, budget: 60, percents: [75, 90], sent: &sent)
        #expect(first.map(\.percent) == [75])
        #expect(first.first?.title == "15 min left: Instagram")
        #expect(first.first?.body == "You've used 45 min of today's 1 h 0 min (75%).")
        #expect(due(limit, used: 46, budget: 60, percents: [75, 90], sent: &sent).isEmpty)
        #expect(due(limit, used: 54, budget: 60, percents: [75, 90], sent: &sent).map(\.percent) == [90])
        #expect(due(limit, used: 58, budget: 60, percents: [75, 90], sent: &sent).isEmpty)
    }

    /// The kid's percentages apply to every limit, each on its own budget.
    @Test func everyLimitWarnsOnItsOwn() {
        let games = AppLimit(name: "Games", items: [], minutes: 30)
        let social = AppLimit(name: "Social", items: [], minutes: 60)
        var plan = EnforcementPlan()
        plan.used = [games.id: 24, social.id: 30]
        plan.budgets = [games.id: 30, social.id: 60]
        var sent: [UUID: LimitWarning.Sent] = [:]
        let warnings = LimitWarning.due(in: plan, limits: [games, social], percents: [50, 80], sent: &sent)
        #expect(warnings.map(\.name) == ["Games", "Social"])
        #expect(warnings.map(\.percent) == [80, 50])
    }

    /// Apple's numbers can dip and come back: the same warning doesn't come twice.
    @Test func useDippingBackDoesNotWarnAgain() {
        let limit = AppLimit(name: "Instagram", items: [], minutes: 60)
        var sent: [UUID: LimitWarning.Sent] = [:]
        #expect(due(limit, used: 45, budget: 60, percents: [75], sent: &sent).count == 1)
        #expect(due(limit, used: 44, budget: 60, percents: [75], sent: &sent).isEmpty)
        #expect(due(limit, used: 45, budget: 60, percents: [75], sent: &sent).isEmpty)
    }

    /// A first look past several percentages gives only the highest.
    @Test func jumpingPastSeveralGivesTheHighest() {
        let limit = AppLimit(name: "Instagram", items: [], minutes: 60)
        var sent: [UUID: LimitWarning.Sent] = [:]
        #expect(due(limit, used: 50, budget: 60, percents: [90, 50, 75], sent: &sent).map(\.percent) == [75])
    }

    /// More time raises the budget: the warnings come again as the new budget runs out.
    @Test func newBudgetWarnsAgain() {
        let limit = AppLimit(name: "Instagram", items: [], minutes: 60)
        var sent: [UUID: LimitWarning.Sent] = [:]
        #expect(due(limit, used: 45, budget: 60, percents: [75], sent: &sent).count == 1)
        #expect(due(limit, used: 50, budget: 80, percents: [75], sent: &sent).isEmpty)
        #expect(due(limit, used: 60, budget: 80, percents: [75], sent: &sent).map(\.left) == [20])
    }

    @Test func noWarningForUsedUpOffOrUnlimitedLimits() {
        let limit = AppLimit(name: "Instagram", items: [], minutes: 60)
        var sent: [UUID: LimitWarning.Sent] = [:]
        #expect(LimitWarning.due(in: plan([limit], used: 60, budget: 60, exhausted: true), limits: [limit],
                                 percents: [75], sent: &sent).isEmpty)
        #expect(due(limit, used: 0, budget: 0, percents: [75], sent: &sent).isEmpty)
        #expect(due(limit, used: 50, budget: 60, percents: [], sent: &sent).isEmpty)
        var unlimited = EnforcementPlan()
        unlimited.used[limit.id] = 500
        #expect(LimitWarning.due(in: unlimited, limits: [limit], percents: [75], sent: &sent).isEmpty)
        var off = limit
        off.enabled = false
        #expect(due(off, used: 50, budget: 60, percents: [75], sent: &sent).isEmpty)
        #expect(sent.isEmpty)
    }

    @Test func plannerUseSetsOffAWarning() {
        let limit = AppLimit(name: "Instagram", items: [instagram.id], minutes: 30)
        let policy = Policy(kidID: testKid.id, limits: [limit], limitWarningPercents: [80])
        let plan = EnforcementPlanner.plan(policy: policy, items: [instagram.id: instagram],
                                           usage: [instagram.id: 24 * 60.0], state: EnforcementDayState(day: testDay),
                                           now: at(12, 0), calendar: utc)
        var sent: [UUID: LimitWarning.Sent] = [:]
        #expect(LimitWarning.due(in: plan, limits: policy.limits, percents: policy.limitWarningPercents, sent: &sent)
            .map(\.left) == [6])
    }

    /// The kid's phone asks for notifications only when some ruleset has warnings and a limit to warn about.
    @Test func hasLimitWarningsNeedsPercentagesAndALimit() {
        let limit = AppLimit(name: "Games", items: [], minutes: 30)
        #expect(!Policy(kidID: testKid.id, limits: [limit]).hasLimitWarnings)
        #expect(!Policy(kidID: testKid.id, limitWarningPercents: [75]).hasLimitWarnings)
        #expect(Policy(kidID: testKid.id, limits: [limit], limitWarningPercents: [75]).hasLimitWarnings)
        let weekday = PolicyRuleSet(name: "Weekday", weekdays: [2, 3, 4, 5, 6], limitWarningPercents: [75])
        var weekend = PolicyRuleSet(name: "Weekend", weekdays: [1, 7], limits: [limit])
        // Weekday warns but has no limit; Weekend has a limit but no warnings.
        #expect(!Policy(kidID: testKid.id, ruleSets: [weekday, weekend]).hasLimitWarnings)
        weekend.limitWarningPercents = [90]
        #expect(Policy(kidID: testKid.id, ruleSets: [weekday, weekend]).hasLimitWarnings)
    }

    @Test func addingAndSteppingSkipPercentagesInUse() {
        var rules = PolicyRuleSet(name: "Weekday")
        var added: [Int] = []
        for _ in 0..<4 {
            guard let next = rules.nextLimitWarning else { break }
            rules.limitWarningPercents.append(next)
            added.append(next)
        }
        #expect(added == [75, 90, 50, 5])
        // 75 up skips 90; 90 up stops at 95, then has nowhere to go.
        #expect(rules.steppingLimitWarning(0, up: true) == 80)
        rules.limitWarningPercents = [85, 90]
        #expect(rules.steppingLimitWarning(0, up: true) == 95)
        rules.limitWarningPercents = [90, 95]
        #expect(rules.steppingLimitWarning(1, up: true) == nil)
        #expect(rules.steppingLimitWarning(1, up: false) == 85)
        rules.limitWarningPercents = Array(stride(from: 5, through: 95, by: 5))
        #expect(rules.nextLimitWarning == nil)
    }

    @Test func oldPoliciesAndDayStatesLoadWithoutWarnings() throws {
        let policy = try JSONDecoder().decode(Policy.self, from: JSONEncoder().encode(Policy(kidID: testKid.id)))
        #expect(policy.limitWarningPercents.isEmpty)
        let state = try JSONDecoder().decode(EnforcementDayState.self, from: JSONEncoder().encode(EnforcementDayState(day: testDay)))
        #expect(state.limitWarnings.isEmpty)
    }

    /// Saved when the warnings were the policy's, for every ruleset: each ruleset gets them. Saved since, each keeps
    /// its own.
    @Test func warningsSavedForEveryRulesetGoToEachOne() throws {
        let sets = [PolicyRuleSet(name: "Weekday", limitWarningPercents: [90]), PolicyRuleSet(name: "Weekend")]
        let policy = Policy(kidID: testKid.id, limitWarningPercents: [75], ruleSets: sets)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(policy)) as? [String: Any])
        let encoded = try #require(json["ruleSets"] as? [[String: Any]])
        json["ruleSets"] = encoded.map { var set = $0; set["limitWarningPercents"] = nil; return set }
        let old = try JSONDecoder().decode(Policy.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.ruleSets.map(\.limitWarningPercents) == [[75], [75]])
        let new = try JSONDecoder().decode(Policy.self, from: JSONEncoder().encode(policy))
        #expect(new.ruleSets.map(\.limitWarningPercents) == [[90], []])
    }

    /// Each ruleset warns its own way: the one in effect's warnings are the policy's for the day, and are saved
    /// with it for older kid builds.
    @Test func theRulesetInEffectWarns() {
        let limit = AppLimit(name: "Games", items: [], minutes: 60)
        var policy = Policy(kidID: testKid.id, limits: [limit], limitWarningPercents: [75]).withDefaultRuleSets()
        #expect(policy.ruleSets.map(\.limitWarningPercents) == [[75], [75], [75]])
        policy.editRuleSet(policy.ruleSets[1].id) { $0.limitWarningPercents = [50, 90] }
        #expect(policy.current(at: at(12, 0), calendar: utc).limitWarningPercents == [50, 90])   // Saturday
        #expect(policy.current(at: at(2 * 24 + 12, 0), calendar: utc).limitWarningPercents == [75])   // Monday
        #expect(policy.saving(at: at(12, 0), calendar: utc).limitWarningPercents == [50, 90])
        #expect(policy.ruleSets[1].copy(name: "Trip").limitWarningPercents == [50, 90])
    }

    @Test func changeHistoryNamesWarnings() {
        let old = Policy(kidID: testKid.id, limitWarningPercents: [75])
        var new = old
        new.limitWarningPercents = [90, 75]
        #expect(PolicyEdit.between(old, new).map { $0.describe(calendar: utc, name: { _ in "" }) }.map(\.details)
            == [["75%, 90%", "Was 75%"]])
        // Order alone isn't a change.
        new.limitWarningPercents = [75]
        #expect(PolicyEdit.between(Policy(kidID: testKid.id, limitWarningPercents: [75]), new).isEmpty)
    }

    @Test func changeHistoryNamesTheRulesetsWarnings() {
        let old = Policy(kidID: testKid.id, limitWarningPercents: [75]).withDefaultRuleSets()
        var new = old
        new.editRuleSet(old.ruleSets[1].id) { $0.limitWarningPercents = [] }
        #expect(PolicyEdit.between(old, new).map { $0.describe(calendar: utc, name: { _ in "" }) }.map(\.title)
            == ["Weekend: Changed limit warnings"])
    }

    /// A temporary change to a ruleset's warnings changes back at its end, like its limits.
    @Test func temporaryWarningsChangeBack() {
        let before = Policy(kidID: testKid.id, limitWarningPercents: [75])
        var after = before
        after.limitWarningPercents = [50, 75, 90]
        let change = TemporaryChange(id: UUID(), until: at(24, 0), before: before, after: after)
        #expect(after.reverting(change).limitWarningPercents == [75])
        let rulesBefore = before.withDefaultRuleSets()
        var rulesAfter = rulesBefore
        rulesAfter.editRuleSet(rulesBefore.ruleSets[1].id) { $0.limitWarningPercents = [90] }
        let ruleChange = TemporaryChange(id: UUID(), until: at(24, 0), before: rulesBefore, after: rulesAfter)
        #expect(rulesAfter.reverting(ruleChange).ruleSets.map(\.limitWarningPercents) == [[75], [75], [75]])
    }
}
