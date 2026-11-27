import Foundation
import Testing
@testable import ThymeCore

/// Rulesets (PLAN.md §15.15). `at(0, 0)` is Saturday 14 November 2026, in UTC.
struct RuleSetTests {
    let kid = testKid.id
    let roblox = UUID(), youtube = UUID()
    let bedtime = DowntimeWindow(name: "Bedtime", startMinute: 21 * 60, endMinute: 7 * 60)
    let games = AppLimit(name: "Games", items: [UUID()], minutes: 60)

    var legacy: Policy { Policy(kidID: kid, updatedAt: dayStart, downtime: [bedtime], limits: [games], blocked: [roblox]) }

    func day(_ offset: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date { at(offset * 24 + hour, minute) }

    /// Downtime windows on at `date` in the policy in force then.
    func downtimeOn(_ policy: Policy, at date: Date) -> [String] {
        policy.current(at: date, calendar: utc).downtime
            .filter { $0.daily.occurrence(containing: date, calendar: utc) != nil }.map(\.name)
    }

    @Test func defaultsHoldTheRulesThePolicyHad() throws {
        let policy = legacy.withDefaultRuleSets()
        #expect(policy.ruleSets.map(\.name) == ["Weekday", "Weekend", "Travel"])
        #expect(policy.ruleSets.map(\.weekdays) == [[2, 3, 4, 5, 6], [1, 7], []])
        let weekday = policy.ruleSets[0], weekend = policy.ruleSets[1]
        #expect(weekday.downtime == [bedtime])
        #expect(weekday.limits == [games])
        #expect(weekend.downtime.map(\.name) == ["Bedtime"])
        #expect(weekend.downtime[0].id != bedtime.id)
        #expect(weekend.limits[0].id != games.id)
        #expect(weekend.blocked == [roblox])
        // The same on every phone, and once only.
        #expect(legacy.withDefaultRuleSets() == policy)
        #expect(policy.withDefaultRuleSets() == policy)
        // Nothing changes on any day.
        for offset in 0..<7 {
            let current = policy.current(at: day(offset), calendar: utc)
            #expect(current.limits.map(\.minutes) == [60])
            #expect(current.blocked == [roblox])
            #expect(downtimeOn(policy, at: day(offset, 22)) == ["Bedtime"])
            #expect(downtimeOn(policy, at: day(offset, 6)) == ["Bedtime"])
        }
    }

    @Test func eachDayHasItsWeekdaysRuleset() {
        var policy = legacy.withDefaultRuleSets()
        policy.editRuleSet(policy.ruleSets[1].id) { $0.limits[0].minutes = 120 }
        #expect(policy.ruleSet(on: day(0), calendar: utc)?.name == "Weekend")   // Saturday
        #expect(policy.ruleSet(on: day(1), calendar: utc)?.name == "Weekend")   // Sunday
        #expect(policy.ruleSet(on: day(2), calendar: utc)?.name == "Weekday")   // Monday
        #expect(policy.current(at: day(0), calendar: utc).limits.map(\.minutes) == [120])
        #expect(policy.current(at: day(2), calendar: utc).limits.map(\.minutes) == [60])
        // A day no ruleset has gets the first's.
        policy.editRuleSet(policy.ruleSets[1].id) { $0.weekdays = [7] }
        #expect(policy.unscheduledWeekdays == [1])
        #expect(policy.ruleSet(on: day(1), calendar: utc)?.name == "Weekday")
    }

    @Test func aChosenRulesetIsInEffectForItsDays() {
        var policy = legacy.withDefaultRuleSets()
        let travel = policy.ruleSets[2]
        policy.editRuleSet(travel.id) { $0.limits = []; $0.blocked = [] }
        policy.ruleSetChoice = RuleSetChoice(ruleSet: travel, days: 3, at: day(-1, 15), by: "Mom", calendar: utc)
        #expect(policy.choice(on: day(-1), calendar: utc) != nil)
        for offset in -1...1 {
            #expect(policy.ruleSet(on: day(offset), calendar: utc)?.name == "Travel")
            #expect(policy.current(at: day(offset), calendar: utc).limits.isEmpty)
        }
        #expect(policy.ruleSet(on: day(2), calendar: utc)?.name == "Weekday")
        #expect(policy.choice(on: day(2), calendar: utc) == nil)
        // Kept a day past its end, for the Downtime that began on its last day; then dropped.
        #expect(policy.current(at: day(2), calendar: utc).ruleSetChoice != nil)
        #expect(policy.current(at: day(3), calendar: utc).ruleSetChoice == nil)
        // "Today only" ends at midnight.
        let today = RuleSetChoice(ruleSet: travel, days: 1, at: day(0, 15), by: "Mom", calendar: utc)
        #expect(today.until == day(1, 0))
        #expect(today.span(calendar: utc) == "Today only")
    }

    @Test func downtimeThatBeganYesterdayKeepsYesterdaysRuleset() {
        var policy = legacy.withDefaultRuleSets()
        // Weekends: bedtime later, and a morning window of their own.
        policy.editRuleSet(policy.ruleSets[1].id) { set in
            set.downtime[0].name = "Late bedtime"
            set.downtime[0].startMinute = 23 * 60
            set.downtime[0].endMinute = 9 * 60
        }
        // Friday night runs into Saturday by Weekday's bedtime.
        #expect(downtimeOn(policy, at: day(-1, 22)) == ["Bedtime"])
        #expect(downtimeOn(policy, at: day(0, 1)) == ["Bedtime"])
        #expect(downtimeOn(policy, at: day(0, 8)).isEmpty)
        // Saturday night is the weekend's, into Sunday morning.
        #expect(downtimeOn(policy, at: day(0, 22)).isEmpty)
        #expect(downtimeOn(policy, at: day(0, 23, 30)) == ["Late bedtime"])
        #expect(downtimeOn(policy, at: day(1, 8)) == ["Late bedtime"])
        // Sunday night's runs into Monday morning, not Weekday's.
        #expect(downtimeOn(policy, at: day(2, 0, 30)) == ["Late bedtime"])
        #expect(downtimeOn(policy, at: day(2, 8)) == ["Late bedtime"])
        #expect(downtimeOn(policy, at: day(2, 22)) == ["Bedtime"])
    }

    @Test func savedRulesAreTheRulesetsAsTheyAre() {
        var policy = legacy.withDefaultRuleSets()
        policy.editRuleSet(policy.ruleSets[1].id) { $0.blocked = [youtube] }
        // Saturday, a day the ruleset changes: in force, bedtime is kept to the day it starts.
        #expect(policy.current(at: day(0), calendar: utc).downtime.map(\.weekdays) == [[6], [7]])
        let saved = policy.saving(at: day(0), calendar: utc)
        #expect(saved.downtime == policy.ruleSets[1].downtime)
        #expect(saved.blocked == [youtube])
        #expect(saved.current(at: day(0), calendar: utc) == policy.current(at: day(0), calendar: utc))
    }

    @Test func aDayBelongsToOneRuleset() {
        var policy = legacy.withDefaultRuleSets()
        var travel = policy.ruleSets[2]
        travel.weekdays = [6, 7]
        policy.save(travel)
        #expect(policy.ruleSets.map(\.weekdays) == [[2, 3, 4, 5], [1], [6, 7]])
        let summer = policy.ruleSets[0].copy(name: "Summer")
        policy.save(summer)
        #expect(policy.ruleSets.count == 4)
        #expect(policy.ruleSets[3].downtime.map(\.name) == ["Bedtime"])
        #expect(Set(policy.ruleSets[3].downtime.map(\.id)).isDisjoint(with: policy.ruleSets[0].downtime.map(\.id)))
        policy.ruleSetChoice = RuleSetChoice(ruleSet: summer, days: 5, at: day(0), by: "Dad", calendar: utc)
        policy.removeRuleSet(summer.id)
        #expect(policy.ruleSets.count == 3)
        #expect(policy.ruleSetChoice == nil)
        for set in policy.ruleSets.dropFirst() { policy.removeRuleSet(set.id) }
        #expect(policy.ruleSets.map(\.name) == ["Weekday"])
        policy.removeRuleSet(policy.ruleSets[0].id)
        #expect(policy.ruleSets.count == 1)
    }

    @Test func aTemporaryChangeToARulesetChangesBack() {
        let policy = legacy.withDefaultRuleSets()
        let weekend = policy.ruleSets[1].id
        var after = policy.current(at: day(0), calendar: utc)
        after.editRuleSet(weekend) { $0.limits[0].minutes = 180; $0.blocked = [] }
        after.temporary.append(TemporaryChange(id: UUID(), until: day(1, 0), before: policy.current(at: day(0), calendar: utc),
                                               after: after))
        #expect(after.current(at: day(0, 20), calendar: utc).limits.map(\.minutes) == [180])
        let back = after.current(at: day(1, 0), calendar: utc)
        #expect(back.ruleSet(weekend)?.limits.map(\.minutes) == [60])
        #expect(back.ruleSet(weekend)?.blocked == [roblox])
        #expect(back.limits.map(\.minutes) == [60])
        #expect(back.temporary.isEmpty)
    }

    @Test func aFirstPolicySavedForSomeDaysKeepsItsRulesets() {
        var after = Policy(kidID: kid).withDefaultRuleSets()
        after.editRuleSet(after.ruleSets[0].id) { $0.downtime = [bedtime] }
        after.temporary = [TemporaryChange(id: UUID(), until: day(1, 0), before: Policy(kidID: kid), after: after)]
        let back = after.current(at: day(1), calendar: utc)
        #expect(back.ruleSets.map(\.name) == ["Weekday", "Weekend", "Travel"])
        #expect(back.ruleSets[0].downtime.isEmpty)
        #expect(back.reverts(through: .distantFuture).isEmpty)
        #expect(after.reverts(through: day(1, 0)).first?.edits.map { $0.describe(calendar: utc, name: { _ in "" }).title }
                == ["Weekday: Removed Downtime \u{201C}Bedtime\u{201D}"])
    }

    @Test func aTemporaryChangeFromBeforeRulesetsStillChangesBack() {
        var after = legacy
        after.limits[0].minutes = 180
        after.temporary = [TemporaryChange(id: UUID(), until: day(3, 0), before: legacy, after: after)]
        let policy = after.withDefaultRuleSets()
        #expect(policy.current(at: day(2), calendar: utc).limits.map(\.minutes) == [180])
        let back = policy.current(at: day(3), calendar: utc)
        #expect(back.ruleSets.map { $0.limits.map(\.minutes) } == [[60], [60], [60]])
    }

    @Test func historyNamesTheRuleset() {
        let edits = PolicyEdit.between(legacy, legacy.withDefaultRuleSets())
        #expect(edits == [.ruleSetsSetUp(["Weekday", "Weekend", "Travel"])])
        let old = legacy.withDefaultRuleSets()
        var new = old
        new.editRuleSet(old.ruleSets[1].id) { $0.blocked.insert(youtube) }
        new.editRuleSet(old.ruleSets[2].id) { $0.name = "Vacation" }
        new.ruleSetChoice = RuleSetChoice(ruleSet: new.ruleSets[2], days: 1, at: day(0), by: "Mom", calendar: utc)
        let name: (UUID) -> String = { $0 == youtube ? "YouTube" : "?" }
        let lines = PolicyEdit.between(old, new).map { $0.describe(calendar: utc, name: name) }
        #expect(lines.map(\.title) == ["Switched to \u{201C}Vacation\u{201D}", "Changed ruleset \u{201C}Vacation\u{201D}",
                                       "Weekend: Changed Blocked"])
        #expect(lines[2].details == ["Added YouTube"])
        // The ruleset in effect is no edit of its own.
        #expect(PolicyEdit.between(old.current(at: day(0), calendar: utc), old.current(at: day(2), calendar: utc)).isEmpty)
        // A kid's first policy lists what each ruleset got.
        var first = Policy(kidID: kid).withDefaultRuleSets()
        first.editRuleSet(first.ruleSets[0].id) { $0.limits = [games] }
        #expect(PolicyEdit.between(Policy(kidID: kid), first).map { $0.describe(calendar: utc, name: name).title }
                == ["Set up rulesets", "Weekday: Added limit \u{201C}Games\u{201D}"])
    }

    @Test func itemsChangeInEveryRuleset() {
        let group = ItemGroup(name: "Fun", items: [youtube])
        var policy = Policy(kidID: kid, downtime: [bedtime], limits: [AppLimit(name: "Fun", items: [group.id], minutes: 30)],
                            blocked: [roblox, group.id], groups: [group]).withDefaultRuleSets()
        policy.removeGroup(group.id)
        for set in policy.ruleSets {
            #expect(set.blocked == [roblox])
            #expect(set.limits[0].items.isEmpty)
        }
        let request = TimeRequest(kidID: kid, itemID: roblox, reason: .alwaysAllow, minutes: nil, at: day(0))
        let allowed = policy.applying(TimeGrant(request: request, approved: true, minutes: nil, at: day(0), by: "Mom"))
        #expect(allowed.ruleSets.allSatisfy { $0.blocked.isEmpty })
        #expect(allowed.allItemIDs.contains(roblox))
    }

    @Test func oldPoliciesLoad() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        json["ruleSets"] = nil
        json["ruleSetChoice"] = nil
        let decoded = try JSONDecoder().decode(Policy.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == legacy)
        #expect(decoded.current(at: day(0), calendar: utc) == legacy)
        var policy = legacy.withDefaultRuleSets()
        policy.ruleSetChoice = RuleSetChoice(ruleSet: policy.ruleSets[2], days: 2, at: day(0), by: "Mom", calendar: utc)
        #expect(try JSONDecoder().decode(Policy.self, from: JSONEncoder().encode(policy)) == policy)
    }
}
