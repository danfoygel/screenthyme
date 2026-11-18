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

    /// Limits and Always Allowed name scanned items, which count through their matches (`TokenPairing`).
    @Test func scannedCategoriesCountThroughTheirMatch() {
        var scannedSocial = TrackedItem(kidID: kid, kind: .category, identifier: TrackedItem.scannedPrefix + "s",
                                        firstSeen: dayStart)
        var scannedInstagram = TrackedItem(kidID: kid, kind: .app, identifier: TrackedItem.scannedPrefix + "i",
                                           firstSeen: dayStart)
        var scannedMessages = TrackedItem(kidID: kid, kind: .app, identifier: TrackedItem.scannedPrefix + "m",
                                          firstSeen: dayStart)
        let unmatched = TrackedItem(kidID: kid, kind: .category, identifier: TrackedItem.scannedPrefix + "u",
                                    firstSeen: dayStart)
        scannedSocial.match = social.id
        scannedInstagram.match = instagram.id
        scannedMessages.match = messages.id
        let all = items.merging([scannedSocial, scannedInstagram, scannedMessages, unmatched].map { ($0.id, $0) }) { a, _ in a }
        // As `UsageSnapshot` gives it: matched scanned items repeat their match's use.
        let usage = [instagram.id: 20 * 60.0, snapchat.id: 11 * 60.0, messages.id: 50 * 60.0,
                     scannedInstagram.id: 20 * 60.0, scannedMessages.id: 50 * 60.0]

        #expect(EnforcementPlanner.categoryNames([scannedSocial.id, unmatched.id], items: all)
            == ["Social", unmatched.identifier])
        // Instagram once, though both the category and its scanned app are targets; Messages is allowed.
        #expect(EnforcementPlanner.seconds(of: [scannedSocial.id, scannedInstagram.id], items: all, usage: usage,
                                           excluding: [scannedMessages.id]) == 31 * 60)
        #expect(EnforcementPlanner.seconds(of: [unmatched.id], items: all, usage: usage) == 0)
        // An allowed scanned category leaves its apps out of all use.
        #expect(EnforcementPlanner.totalSeconds(items: all, usage: usage, excluding: [scannedSocial.id]) == 0)
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

    @Test func scannedItemGrantLastsForItsMinutesOfClock() {
        // A scanned app has a token but no usage in Apple's data, so its grant runs by the clock.
        let scanned = TrackedItem(kidID: kid, kind: .app, identifier: TrackedItem.scannedPrefix + "ab12", firstSeen: dayStart)
        let window = DowntimeWindow(name: "Night", startMinute: 20 * 60, endMinute: 23 * 60)
        let request = TimeRequest(kidID: kid, itemID: scanned.id, reason: .downtime(window.id), minutes: 15, at: at(21, 0))
        var state = EnforcementDayState(day: testDay)
        state.grants = [AppliedGrant(grant: TimeGrant(request: request, approved: true, minutes: 15, at: at(21, 1), by: "Parent"),
                                     appliedAt: at(21, 1), windowStart: at(20, 0))]
        let policy = Policy(kidID: kid, downtime: [window])
        #expect(plan(policy, state: state, at: at(21, 15)).downtimeExceptions == [scanned.id])
        #expect(plan(policy, state: state, at: at(21, 16)).downtimeExceptions.isEmpty)
        #expect(scanned.isScanned && scanned.displayName == "App")
    }

    @Test func phoneWideGrantPausesDowntimeByTheClock() {
        let window = DowntimeWindow(name: "Night", startMinute: 20 * 60, endMinute: 23 * 60)
        let request = TimeRequest(kidID: kid, itemID: nil, reason: .downtime(window.id), minutes: 15, at: at(21, 0))
        var state = EnforcementDayState(day: testDay)
        state.grants = [AppliedGrant(grant: TimeGrant(request: request, approved: true, minutes: 15, at: at(21, 1), by: "Parent"),
                                     appliedAt: at(21, 1), windowStart: at(20, 0))]
        let policy = Policy(kidID: kid, downtime: [window])
        #expect(plan(policy, state: state, at: at(21, 15)).downtime == nil)
        #expect(plan(policy, state: state, at: at(21, 16)).downtime?.windowID == window.id)
        // It belongs to tonight's window only.
        #expect(plan(policy, state: state, at: at(20, 30)).downtime == nil)
    }

    @Test func oneMoreMinuteOnADowntimeCategoryShieldPausesDowntimeForAMinute() {
        let window = DowntimeWindow(name: "Night", startMinute: 20 * 60, endMinute: 23 * 60)
        let policy = Policy(kidID: kid, downtime: [window])
        var state = EnforcementDayState(day: testDay)
        state.extraMinutes = [ExtraMinute(itemID: nil, reason: .downtime(window.id), at: at(21, 0, 30))]
        let during = plan(policy, state: state, at: at(21, 1))
        #expect(during.downtime == nil)
        #expect(during.extraMinuteEnds == at(21, 1, 30))
        let after = plan(policy, state: state, at: at(21, 1, 30))
        #expect(after.downtime?.windowID == window.id)
        #expect(after.extraMinuteEnds == nil)
    }

    @Test func oneMoreMinuteForAnAppLetsOnlyThatAppThrough() {
        let window = DowntimeWindow(name: "Night", startMinute: 20 * 60, endMinute: 23 * 60)
        let limit = AppLimit(name: "Social", items: [instagram.id, snapchat.id], minutes: 30)
        let policy = Policy(kidID: kid, downtime: [window], limits: [limit])
        var state = EnforcementDayState(day: testDay)
        state.extraMinutes = [ExtraMinute(itemID: instagram.id, reason: .limit(limit.id), at: at(12, 0))]
        let usage = [instagram.id: 31 * 60.0]
        let noon = plan(policy, usage: usage, state: state, at: at(12, 0, 59))
        #expect(noon.exhaustedLimits == [limit.id])
        #expect(noon.limitedItems == [snapchat.id])
        #expect(plan(policy, usage: usage, state: state, at: at(12, 1)).limitedItems == [instagram.id, snapchat.id])

        state.extraMinutes = [ExtraMinute(itemID: instagram.id, reason: .downtime(window.id), at: at(21, 0))]
        #expect(plan(policy, state: state, at: at(21, 0, 30)).downtimeExceptions == [instagram.id])
        #expect(plan(policy, state: state, at: at(21, 1)).downtimeExceptions.isEmpty)
    }

    @Test func oneMoreMinuteOnACategoryLimitLiftsTheCategory() {
        let limit = AppLimit(name: "Social", items: [social.id], minutes: 30)
        var state = EnforcementDayState(day: testDay)
        state.extraMinutes = [ExtraMinute(itemID: social.id, reason: .limit(limit.id), at: at(12, 0))]
        let result = plan(Policy(kidID: kid, limits: [limit]), usage: [instagram.id: 40 * 60.0], state: state, at: at(12, 0, 30))
        #expect(result.exhaustedLimits == [limit.id])
        #expect(result.limitedItems.isEmpty)
    }

    @Test func allAppsLimitCountsEverythingButAllowedAndExempt() {
        let safari = TrackedItem(kidID: kid, kind: .app, identifier: "com.apple.mobilesafari", firstSeen: dayStart)
        let khan = TrackedItem(kidID: kid, kind: .domain, identifier: "www.khanacademy.org", firstSeen: dayStart)
        let screenThyme = TrackedItem(kidID: kid, kind: .app, identifier: "com.danfoygel.screenthyme", firstSeen: dayStart)
        var scanned = TrackedItem(kidID: kid, kind: .app, identifier: TrackedItem.scannedPrefix + "abc", firstSeen: dayStart)
        scanned.match = snapchat.id
        var all = items
        for item in [safari, khan, screenThyme, scanned] { all[item.id] = item }
        let limit = AppLimit(name: "All apps", items: [], allApps: true, minutes: 60)
        let policy = Policy(kidID: kid, alwaysAllowed: [messages.id, khan.id], limits: [limit])
        // Instagram 20 + Snapchat 15 (its scanned copy not again) + Safari 30 less the allowed site's 10; not Messages
        // (always allowed) or ScreenThyme (exempt).
        let minutes: [UUID: Double] = [instagram.id: 20, snapchat.id: 15, scanned.id: 15, messages.id: 50, safari.id: 30,
                                       khan.id: 10, screenThyme.id: 30]
        let usage = minutes.mapValues { $0 * 60 }
        func result(_ usage: [UUID: Double], state: EnforcementDayState = EnforcementDayState(day: testDay),
                    at date: Date = at(12, 0)) -> EnforcementPlan {
            EnforcementPlanner.plan(policy: policy, items: all, usage: usage, state: state, now: date,
                                    exempt: [screenThyme.id], calendar: utc)
        }
        let noon = result(usage)
        #expect(noon.used[limit.id] == 55)
        #expect(!noon.allAppsLimited)

        var more = usage
        more[instagram.id] = 25 * 60.0
        let over = result(more)
        #expect(over.exhaustedLimits == [limit.id])
        #expect(over.allAppsLimited)
        #expect(over.limitedItems.isEmpty)

        // One more minute, pressed on the shield (a category), is for the whole phone.
        var state = EnforcementDayState(day: testDay)
        state.extraMinutes = [ExtraMinute(itemID: nil, reason: .limit(limit.id), at: at(12, 0))]
        #expect(!result(more, state: state, at: at(12, 0, 30)).allAppsLimited)
        #expect(result(more, state: state, at: at(12, 1)).allAppsLimited)
        #expect(!state.canTakeExtraMinute(itemID: nil, reason: .limit(limit.id)))
    }

    @Test func limitsAndPlansSavedBeforeAllAppsStillLoad() throws {
        let id = UUID()
        let json = #"{"id":"\#(id)","name":"Social","items":[],"minutes":30,"weekdayMinutes":{},"enabled":true}"#
        let limit = try JSONDecoder().decode(AppLimit.self, from: Data(json.utf8))
        #expect(limit.id == id)
        #expect(!limit.allApps)
        let plan = try JSONDecoder().decode(EnforcementPlan.self, from: Data(#"{"exhaustedLimits":["\#(id)"]}"#.utf8))
        #expect(plan.exhaustedLimits == [id])
        #expect(!plan.allAppsLimited)
    }

    @Test func oneMoreMinuteIsOnceADayPerApp() {
        let window = DowntimeWindow(name: "Night", startMinute: 20 * 60, endMinute: 23 * 60)
        let limit = AppLimit(name: "Social", items: [social.id], minutes: 30)
        var state = EnforcementDayState(day: testDay)
        #expect(state.canTakeExtraMinute(itemID: instagram.id, reason: .limit(limit.id)))
        #expect(!state.canTakeExtraMinute(itemID: instagram.id, reason: .blocked))
        state.extraMinutes = [ExtraMinute(itemID: instagram.id, reason: .limit(limit.id), at: at(12, 0))]
        #expect(!state.canTakeExtraMinute(itemID: instagram.id, reason: .limit(limit.id)))
        #expect(!state.canTakeExtraMinute(itemID: instagram.id, reason: .downtime(window.id)))
        #expect(state.canTakeExtraMinute(itemID: snapchat.id, reason: .limit(limit.id)))
        // With no app (a Downtime category shield): once per window.
        #expect(state.canTakeExtraMinute(itemID: nil, reason: .downtime(window.id)))
        state.extraMinutes.append(ExtraMinute(itemID: nil, reason: .downtime(window.id), at: at(21, 0)))
        #expect(!state.canTakeExtraMinute(itemID: nil, reason: .downtime(window.id)))
        #expect(state.canTakeExtraMinute(itemID: nil, reason: .downtime(UUID())))
    }

    @Test func dayStateWithoutExtraMinutesStillLoads() throws {
        let json = #"{"day":"2026-11-14","limitFires":[],"grants":[]}"#
        let state = try JSONDecoder().decode(EnforcementDayState.self, from: Data(json.utf8))
        #expect(state.day == testDay && state.extraMinutes.isEmpty)
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
