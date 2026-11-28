import Foundation
import Testing
@testable import ThymeCore

struct LimitWarningTests {
    let instagram = TrackedItem(kidID: testKid.id, kind: .app, identifier: "com.burbn.instagram", category: "Social",
                                firstSeen: dayStart)

    func plan(_ limit: AppLimit, used: Int, budget: Int, exhausted: Bool = false) -> EnforcementPlan {
        var plan = EnforcementPlan()
        plan.used[limit.id] = used
        plan.budgets[limit.id] = budget
        if exhausted { plan.exhaustedLimits = [limit.id] }
        return plan
    }

    @Test func warnsOnceAtEachPercentageReached() {
        let limit = AppLimit(name: "Instagram", items: [], minutes: 60, warningPercents: [75, 90])
        var sent: [UUID: LimitWarning.Sent] = [:]
        #expect(LimitWarning.due(in: plan(limit, used: 44, budget: 60), limits: [limit], sent: &sent).isEmpty)
        let first = LimitWarning.due(in: plan(limit, used: 45, budget: 60), limits: [limit], sent: &sent)
        #expect(first.map(\.percent) == [75])
        #expect(first.first?.title == "15 min left: Instagram")
        #expect(first.first?.body == "You've used 45 min of today's 1 h 0 min (75%).")
        #expect(LimitWarning.due(in: plan(limit, used: 46, budget: 60), limits: [limit], sent: &sent).isEmpty)
        #expect(LimitWarning.due(in: plan(limit, used: 54, budget: 60), limits: [limit], sent: &sent).map(\.percent) == [90])
        #expect(LimitWarning.due(in: plan(limit, used: 58, budget: 60), limits: [limit], sent: &sent).isEmpty)
    }

    /// Apple's numbers can dip and come back: the same warning doesn't come twice.
    @Test func useDippingBackDoesNotWarnAgain() {
        let limit = AppLimit(name: "Instagram", items: [], minutes: 60, warningPercents: [75])
        var sent: [UUID: LimitWarning.Sent] = [:]
        #expect(LimitWarning.due(in: plan(limit, used: 45, budget: 60), limits: [limit], sent: &sent).count == 1)
        #expect(LimitWarning.due(in: plan(limit, used: 44, budget: 60), limits: [limit], sent: &sent).isEmpty)
        #expect(LimitWarning.due(in: plan(limit, used: 45, budget: 60), limits: [limit], sent: &sent).isEmpty)
    }

    /// A first look past several percentages gives only the highest.
    @Test func jumpingPastSeveralGivesTheHighest() {
        let limit = AppLimit(name: "Instagram", items: [], minutes: 60, warningPercents: [50, 75, 90])
        var sent: [UUID: LimitWarning.Sent] = [:]
        #expect(LimitWarning.due(in: plan(limit, used: 50, budget: 60), limits: [limit], sent: &sent).map(\.percent) == [75])
    }

    /// More time raises the budget: the warnings come again as the new budget runs out.
    @Test func newBudgetWarnsAgain() {
        let limit = AppLimit(name: "Instagram", items: [], minutes: 60, warningPercents: [75])
        var sent: [UUID: LimitWarning.Sent] = [:]
        #expect(LimitWarning.due(in: plan(limit, used: 45, budget: 60), limits: [limit], sent: &sent).count == 1)
        #expect(LimitWarning.due(in: plan(limit, used: 50, budget: 80), limits: [limit], sent: &sent).isEmpty)
        let again = LimitWarning.due(in: plan(limit, used: 60, budget: 80), limits: [limit], sent: &sent)
        #expect(again.map(\.left) == [20])
    }

    @Test func noWarningForUsedUpOffOrUnlimitedLimits() {
        let limit = AppLimit(name: "Instagram", items: [], minutes: 60, warningPercents: [75])
        var sent: [UUID: LimitWarning.Sent] = [:]
        #expect(LimitWarning.due(in: plan(limit, used: 60, budget: 60, exhausted: true), limits: [limit], sent: &sent).isEmpty)
        #expect(LimitWarning.due(in: plan(limit, used: 0, budget: 0), limits: [limit], sent: &sent).isEmpty)
        var unlimited = EnforcementPlan()
        unlimited.used[limit.id] = 500
        #expect(LimitWarning.due(in: unlimited, limits: [limit], sent: &sent).isEmpty)
        var off = limit
        off.enabled = false
        #expect(LimitWarning.due(in: plan(off, used: 50, budget: 60), limits: [off], sent: &sent).isEmpty)
        #expect(sent.isEmpty)
    }

    @Test func plannerUseSetsOffAWarning() {
        let limit = AppLimit(name: "Instagram", items: [instagram.id], minutes: 30, warningPercents: [80])
        let plan = EnforcementPlanner.plan(policy: Policy(kidID: testKid.id, limits: [limit]),
                                           items: [instagram.id: instagram], usage: [instagram.id: 24 * 60.0],
                                           state: EnforcementDayState(day: testDay), now: at(12, 0), calendar: utc)
        var sent: [UUID: LimitWarning.Sent] = [:]
        #expect(LimitWarning.due(in: plan, limits: [limit], sent: &sent).map(\.left) == [6])
    }

    @Test func oldLimitsAndDayStatesLoadWithoutWarnings() throws {
        let limit = try JSONDecoder().decode(AppLimit.self, from: Data("""
            {"id":"\(UUID().uuidString)","name":"Games","items":[],"minutes":30}
            """.utf8))
        #expect(limit.warningPercents.isEmpty)
        let state = try JSONDecoder().decode(EnforcementDayState.self, from: JSONEncoder().encode(EnforcementDayState(day: testDay)))
        #expect(state.limitWarnings.isEmpty)
    }

    @Test func changeHistoryNamesWarnings() {
        let old = AppLimit(name: "Games", items: [], minutes: 30)
        var new = old
        new.warningPercents = [90, 75]
        let (_, details) = PolicyEdit.limitChanged(from: old, to: new).describe(calendar: utc, name: { _ in "" })
        #expect(details == ["Warns at 75%, 90%"])
    }
}
