import Foundation
import Testing
@testable import ThymeCore

struct EnforcementTests {
    let kid = testKid.id
    let instagram = TrackedItem(kidID: testKid.id, kind: .app, identifier: "com.burbn.instagram", category: "Social",
                                firstSeen: dayStart)
    let snapchat = TrackedItem(kidID: testKid.id, kind: .app, identifier: "com.toyopagroup.picaboo", category: "Social",
                               firstSeen: dayStart)
    let messages = TrackedItem(kidID: testKid.id, kind: .app, identifier: "com.apple.MobileSMS", category: "Social",
                               firstSeen: dayStart)
    let social = TrackedItem(kidID: testKid.id, kind: .category, identifier: "Social", firstSeen: dayStart)
    var items: [UUID: TrackedItem] { Dictionary(uniqueKeysWithValues: [instagram, snapchat, messages, social].map { ($0.id, $0) }) }

    func plan(_ policy: Policy, usage: [UUID: Double] = [:], state: EnforcementDayState? = nil, at date: Date,
              ending: Set<UUID> = []) -> EnforcementPlan {
        EnforcementPlanner.plan(policy: policy, items: items, usage: usage, state: state ?? EnforcementDayState(day: testDay),
                                now: date, endingWindows: ending, calendar: utc)
    }

    @Test func downtimeWrapsMidnightOnTheStartingWeekday() {
        // Nov 14, 2026 is a Saturday (7). A Friday-night window covers Saturday 1:00, a Saturday-night one doesn't.
        let friday = DowntimeWindow(name: "Bedtime", startMinute: 21 * 60 + 30, endMinute: 7 * 60, weekdays: [6])
        #expect(plan(Policy(kidID: kid, downtime: [friday]), at: at(1, 0)).downtime?.windowID == friday.id)
        let saturday = DowntimeWindow(name: "Bedtime", startMinute: 21 * 60 + 30, endMinute: 7 * 60, weekdays: [7])
        #expect(plan(Policy(kidID: kid, downtime: [saturday]), at: at(1, 0)).downtime == nil)
        #expect(plan(Policy(kidID: kid, downtime: [saturday]), at: at(22, 0)).downtime?.interval.end == at(31, 0))
    }

    @Test func endingWindowIsOffEvenIfCalledEarly() {
        let window = DowntimeWindow(name: "School", startMinute: 8 * 60, endMinute: 15 * 60)
        let policy = Policy(kidID: kid, downtime: [window])
        #expect(plan(policy, at: at(14, 59, 59)).downtime != nil)
        #expect(plan(policy, at: at(14, 59, 59), ending: [window.id]).downtime == nil)
    }

    @Test func alwaysAllowedIsExemptFromDowntimeAndLimits() {
        let limit = AppLimit(name: "Social", items: [social.id], minutes: 30)
        let policy = Policy(kidID: kid, downtime: [DowntimeWindow(name: "Night", startMinute: 0, endMinute: 6 * 60)],
                            alwaysAllowed: [messages.id], limits: [limit])
        let usage = [instagram.id: 20 * 60.0, messages.id: 50 * 60.0]
        let night = plan(policy, usage: usage, at: at(1, 0))
        #expect(night.downtimeExceptions == [messages.id])
        // Messages' 50 minutes don't count against Social; Instagram's 20 don't exhaust 30.
        #expect(night.used[limit.id] == 20)
        #expect(night.exhaustedLimits.isEmpty)
    }

    @Test func categoryLimitCountsItsAppsOnce() {
        let limit = AppLimit(name: "Social", items: [social.id, instagram.id], minutes: 30)
        let usage = [instagram.id: 20 * 60.0, snapchat.id: 11 * 60.0]
        let result = plan(Policy(kidID: kid, limits: [limit]), usage: usage, at: at(12, 0))
        #expect(result.used[limit.id] == 31)
        #expect(result.exhaustedLimits == [limit.id])
        #expect(result.limitedItems == [social.id, instagram.id])
    }

    @Test func limitFireExhaustsBeforeAppleDataCatchesUp() {
        let limit = AppLimit(name: "Instagram", items: [instagram.id], minutes: 30)
        var state = EnforcementDayState(day: testDay)
        state.limitFires[limit.id] = 30
        let result = plan(Policy(kidID: kid, limits: [limit]), usage: [instagram.id: 29 * 60.0], state: state, at: at(12, 0))
        #expect(result.exhaustedLimits == [limit.id])
    }

    @Test func limitGrantsRaiseTheBudget() {
        let limit = AppLimit(name: "Instagram", items: [instagram.id], minutes: 30, weekdayMinutes: [7: 60])
        let request = TimeRequest(kidID: kid, itemID: instagram.id, reason: .limit(limit.id), minutes: 15, at: at(12, 0))
        var state = EnforcementDayState(day: testDay)
        state.limitFires[limit.id] = 60  // Saturday's budget
        state.grants = [AppliedGrant(grant: TimeGrant(request: request, approved: true, minutes: 15, at: at(12, 1), by: "Parent"),
                                     appliedAt: at(12, 1))]
        let result = plan(Policy(kidID: kid, limits: [limit]), usage: [instagram.id: 61 * 60.0], state: state, at: at(12, 2))
        #expect(result.budgets[limit.id] == 75)
        #expect(result.exhaustedLimits.isEmpty)
        // A declined request changes nothing.
        state.grants = [AppliedGrant(grant: TimeGrant(request: request, approved: false, minutes: nil, at: at(12, 1), by: "Parent"),
                                     appliedAt: at(12, 1))]
        #expect(plan(Policy(kidID: kid, limits: [limit]), usage: [instagram.id: 61 * 60.0], state: state, at: at(12, 2))
            .exhaustedLimits == [limit.id])
    }

    @Test func downtimeGrantLastsForItsMinutesOfUse() {
        let window = DowntimeWindow(name: "Night", startMinute: 20 * 60, endMinute: 23 * 60)
        let request = TimeRequest(kidID: kid, itemID: instagram.id, reason: .downtime(window.id), minutes: 15, at: at(21, 0))
        var state = EnforcementDayState(day: testDay)
        state.grants = [AppliedGrant(grant: TimeGrant(request: request, approved: true, minutes: 15, at: at(21, 1), by: "Parent"),
                                     appliedAt: at(21, 1), baselineSeconds: 40 * 60, windowStart: at(20, 0))]
        let policy = Policy(kidID: kid, downtime: [window])
        #expect(plan(policy, usage: [instagram.id: 50 * 60.0], state: state, at: at(21, 20)).downtimeExceptions == [instagram.id])
        #expect(plan(policy, usage: [instagram.id: 55 * 60.0], state: state, at: at(21, 30)).downtimeExceptions.isEmpty)
    }

    @Test func yesterdaysStateIsIgnored() {
        let limit = AppLimit(name: "Instagram", items: [instagram.id], minutes: 30)
        var state = EnforcementDayState(day: DayKey(year: 2026, month: 11, day: 13))
        state.limitFires[limit.id] = 30
        #expect(plan(Policy(kidID: kid, limits: [limit]), state: state, at: at(9, 0)).exhaustedLimits.isEmpty)
    }

    @Test func disabledPolicyBlocksNothing() {
        let policy = Policy(kidID: kid, enabled: false, downtime: [DowntimeWindow(name: "All day", startMinute: 0, endMinute: 1439)],
                            blocked: [instagram.id])
        #expect(plan(policy, at: at(12, 0)) == EnforcementPlan())
    }
}
