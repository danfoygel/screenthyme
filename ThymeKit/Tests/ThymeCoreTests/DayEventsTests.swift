import Foundation
import Testing
@testable import ThymeCore

/// The moments the day's calendar marks beside the use, and which limits a new plan finds used up.
struct DayEventsTests {
    let item = UUID()
    let limit = UUID()

    private func build(limitsReached: [LimitReached] = [], requests: [TimeRequest] = [], grants: [TimeGrant] = [],
                       extraMinutes: [ExtraMinuteUse] = [], alerts: [AlertRecord] = []) -> [DayEvent] {
        DayEvents.build(day: testDay, calendar: utc, kidName: testKid.displayName, limitsReached: limitsReached,
                        requests: requests, grants: grants, extraMinutes: extraMinutes, alerts: alerts)
    }

    @Test func eventsComeInTimeOrderAndOnlyFromTheDay() {
        let reached = LimitReached(kidID: testKid.id, limitID: limit, name: "Games", minutes: 60, at: at(16, 40))
        let yesterday = LimitReached(kidID: testKid.id, limitID: limit, name: "Games", minutes: 60, at: at(-2, 0))
        let minute = ExtraMinuteUse(kidID: testKid.id, itemID: item, reason: .limit(limit), at: at(16, 41), minutes: 1)
        let request = TimeRequest(kidID: testKid.id, itemID: item, reason: .limit(limit), minutes: 20, at: at(16, 43))
        let grant = TimeGrant(request: request, approved: true, minutes: 20, at: at(16, 45), by: "Mom")
        let events = build(limitsReached: [reached, yesterday], requests: [request], grants: [grant],
                           extraMinutes: [minute])
        #expect(events.map(\.title) == ["Games limit reached", "One more minute", "Asked for 20 more minutes",
                                        "Mom said yes"])
        #expect(events.map(\.at) == [at(16, 40), at(16, 41), at(16, 43), at(16, 45)])
        #expect(events[0].itemID == nil)
        #expect(events[1].itemID == item)
    }

    @Test func answersSayWhatWasGiven() {
        let request = TimeRequest(kidID: testKid.id, itemID: item, reason: .limit(limit), minutes: 60, at: at(9, 0))
        func title(_ grant: TimeGrant) -> [String] {
            build(grants: [grant]).map(\.title)
        }
        #expect(DayEvents.answerTitle(TimeGrant(request: request, approved: true, minutes: 30, at: at(9, 1), by: "Dad"), request)
            == "Dad gave 30 more minutes")
        #expect(DayEvents.answerTitle(TimeGrant(request: request, approved: false, minutes: nil, at: at(9, 1), by: "Dad"), request)
            == "Dad said no")
        #expect(DayEvents.answerTitle(.selfApproved(request, by: "Emma", because: "homework app", at: at(9, 1)), request)
            == "Self-approved 1 more hour")
        let always = TimeRequest(kidID: testKid.id, itemID: item, reason: .alwaysAllow, minutes: nil, at: at(9, 0))
        #expect(DayEvents.answerTitle(TimeGrant(request: always, approved: true, minutes: nil, at: at(9, 1), by: "Mom"), always)
            == "Mom allowed it always")
        // Without its request, the answer says what it gave.
        #expect(title(TimeGrant(request: request, approved: true, minutes: 60, at: at(9, 1), by: "Mom"))
            == ["Mom gave 1 more hour"])
    }

    @Test func anEndedGrantIsTwoEventsOnce() {
        let request = TimeRequest(kidID: testKid.id, itemID: item, reason: .limit(limit), minutes: 30, at: at(9, 0))
        let grant = TimeGrant(request: request, approved: true, minutes: 30, at: at(9, 1), by: "Mom")
        let events = build(requests: [request], grants: [grant, grant.ending(at: at(9, 10), by: "Dad"), grant])
        #expect(events.map(\.title) == ["Asked for 30 more minutes", "Mom said yes", "Dad ended it early"])
    }

    @Test func alertsSentWithRequestsAreLeftOutAndTitlesDropTheKidsName() {
        let request = TimeRequest(kidID: testKid.id, itemID: item, reason: .limit(limit), minutes: 30, at: at(9, 0))
        let sent = AlertRecord(kidID: testKid.id, ruleID: nil, itemID: item, at: at(9, 0), title: "Emma asks for more time",
                               body: "")
        let rule = AlertRecord(kidID: testKid.id, ruleID: UUID(), itemID: nil, at: at(10, 0),
                               title: "Emma: phone over 120 min", body: "")
        let lost = AlertRecord(kidID: testKid.id, ruleID: nil, itemID: nil, at: at(11, 0),
                               title: "Emma: ScreenThyme lost usage data", body: "")
        let events = build(requests: [request], alerts: [sent, rule, lost])
        #expect(events.map(\.title) == ["Asked for 30 more minutes", "Phone over 120 min", "ScreenThyme lost usage data"])
    }

    @Test func labelsTooCloseArePushedDown() {
        #expect(DayEvents.spread([10, 12, 50, 55, 90], spacing: 20) == [10, 30, 50, 70, 90])
        #expect(DayEvents.spread([], spacing: 20) == [])
    }

    @Test func onlyLimitsNewlyUsedUpAreReached() {
        let other = UUID()
        var before = EnforcementPlan()
        before.exhaustedLimits = [other]
        var plan = EnforcementPlan()
        plan.exhaustedLimits = [limit, other]
        plan.budgets = [limit: 45, other: 60]
        let reached = LimitReached.newlyReached(in: plan, previous: before, names: [limit: "Games"], kidID: testKid.id,
                                                at: at(15, 0))
        #expect(reached.map(\.limitID) == [limit])
        #expect(reached.first?.name == "Games")
        #expect(reached.first?.minutes == 45)
        // On a new day there's no plan before it: every used-up limit counts.
        #expect(LimitReached.newlyReached(in: plan, previous: nil, names: [:], kidID: testKid.id, at: at(0, 1)).count == 2)
        #expect(LimitReached.newlyReached(in: plan, previous: plan, names: [:], kidID: testKid.id, at: at(15, 1)).isEmpty)
    }
}
