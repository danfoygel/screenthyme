import Foundation
import Testing
@testable import ThymeCore

struct AppDetailsTests {
    let kid = testKid.id
    let roblox = TrackedItem(kidID: testKid.id, kind: .app, identifier: "com.roblox.robloxmobile", category: "Games",
                             firstSeen: dayStart)
    let messages = TrackedItem(kidID: testKid.id, kind: .app, identifier: "com.apple.MobileSMS", category: "Social",
                               firstSeen: dayStart)
    let games = TrackedItem(kidID: testKid.id, kind: .category, identifier: "Games", firstSeen: dayStart)
    /// The scan's Roblox and Games, matched to Apple's.
    var scannedRoblox: TrackedItem {
        var item = TrackedItem(kidID: kid, kind: .app, identifier: TrackedItem.scannedPrefix + "r", tokenData: Data([1]),
                               firstSeen: dayStart)
        item.match = roblox.id
        return item
    }
    var scannedGames: TrackedItem {
        var item = TrackedItem(kidID: kid, kind: .category, identifier: TrackedItem.scannedPrefix + "g", tokenData: Data([2]),
                               firstSeen: dayStart)
        item.match = games.id
        return item
    }
    var items: [UUID: TrackedItem] {
        Dictionary(uniqueKeysWithValues: [roblox, messages, games, scannedRoblox, scannedGames].map { ($0.id, $0) })
    }

    @Test func coversBothItemsOfAMatchedApp() {
        for item in [roblox, scannedRoblox] {
            let details = AppDetails(item: item, items: items, policy: Policy(kidID: kid))
            #expect(details.ids == [roblox.id, scannedRoblox.id])
            #expect(details.usageItem == roblox)
            #expect(details.tokenItem == scannedRoblox)
            #expect(details.categoryName == "Games")
            #expect(details.categoryIDs == [games.id, scannedGames.id])
        }
        let unmatched = AppDetails(item: messages, items: items, policy: Policy(kidID: kid))
        #expect(unmatched.tokenItem == nil)
    }

    @Test func findsGroupsListsDowntimeAndLimitsThroughGroupsAndCategories() {
        let group = ItemGroup(name: "Fun", items: [scannedGames.id])
        let other = ItemGroup(name: "School", items: [messages.id])
        let bedtime = DowntimeWindow(name: "Bedtime", startMinute: 21 * 60, endMinute: 7 * 60)
        let homework = DowntimeWindow(name: "Homework", startMinute: 16 * 60, endMinute: 18 * 60, items: [group.id])
        let chat = DowntimeWindow(name: "Chat", startMinute: 12 * 60, endMinute: 13 * 60, items: [messages.id])
        let gameLimit = AppLimit(name: "Roblox", items: [scannedRoblox.id], minutes: 30)
        let all = AppLimit(name: "All", items: [], allApps: true, minutes: 120)
        let policy = Policy(kidID: kid, downtime: [bedtime, homework, chat], limits: [gameLimit, all],
                            blocked: [scannedGames.id], groups: [group, other])
        let details = AppDetails(item: roblox, items: items, policy: policy)
        #expect(details.groups == [group])
        #expect(details.via(group) == [.category(scannedGames.id)])
        #expect(details.blocked == [.category(scannedGames.id)])
        #expect(details.alwaysAllowed.isEmpty)
        #expect(details.downtime.map(\.window.name) == ["Bedtime", "Homework"])
        #expect(details.downtime.map(\.via) == [[.everything], [.group(group.id)]])
        #expect(details.limits.map(\.via) == [[.item], [.everything]])
    }

    @Test func alwaysAllowedLeavesOutWholePhoneDowntimeAndAllAppsLimits() {
        let bedtime = DowntimeWindow(name: "Bedtime", startMinute: 21 * 60, endMinute: 7 * 60)
        let all = AppLimit(name: "All", items: [], allApps: true, minutes: 120)
        let policy = Policy(kidID: kid, downtime: [bedtime], alwaysAllowed: [scannedRoblox.id], limits: [all])
        let details = AppDetails(item: roblox, items: items, policy: policy)
        #expect(details.isAlwaysAllowed)
        #expect(details.downtime.isEmpty && details.limits.isEmpty)
        let exempt = AppDetails(item: messages, items: items, policy: policy, exempt: [messages.id])
        #expect(exempt.isAlwaysAllowed && exempt.downtime.isEmpty)
    }

    @Test func statusFollowsThePlan() {
        let limit = AppLimit(name: "Games", items: [scannedGames.id], minutes: 30)
        let homework = DowntimeWindow(name: "Homework", startMinute: 16 * 60, endMinute: 18 * 60, items: [scannedRoblox.id])
        let policy = Policy(kidID: kid, downtime: [homework], limits: [limit])
        let details = AppDetails(item: roblox, items: items, policy: policy)
        func status(_ usage: Double, _ date: Date) -> AppDetails.Status {
            let plan = EnforcementPlanner.plan(policy: policy, items: items, usage: [roblox.id: usage, scannedRoblox.id: usage],
                                               state: EnforcementDayState(day: testDay), now: date, calendar: utc)
            return details.status(in: plan, policy: policy)
        }
        #expect(status(10 * 60, at(12, 0)) == .open)
        #expect(status(31 * 60, at(12, 0)) == .limit(name: "Games"))
        #expect(status(10 * 60, at(17, 0)) == .downtime(name: "Homework", until: at(18, 0)))
        var off = policy
        off.enabled = false
        #expect(details.status(in: EnforcementPlan(), policy: off) == .notEnforced)
    }

    @Test func limitReachedLooksPastDowntime() {
        let limit = AppLimit(name: "Games", items: [scannedGames.id], minutes: 30)
        let all = AppLimit(name: "All", items: [], allApps: true, minutes: 60)
        let bedtime = DowntimeWindow(name: "Bedtime", startMinute: 21 * 60, endMinute: 7 * 60)
        let policy = Policy(kidID: kid, downtime: [bedtime], limits: [limit, all])
        let details = AppDetails(item: roblox, items: items, policy: policy)
        func plan(_ seconds: Double) -> EnforcementPlan {
            EnforcementPlanner.plan(policy: policy, items: items, usage: [roblox.id: seconds, scannedRoblox.id: seconds],
                                    state: EnforcementDayState(day: testDay), now: at(23, 59, 59), calendar: utc)
        }
        // The day's last moment is in Bedtime, but the limit it went over still shows.
        #expect(details.status(in: plan(31 * 60), policy: policy) == .downtime(name: "Bedtime", until: testDay.adding(days: 1, calendar: utc).start(in: utc).addingTimeInterval(7 * 3600)))
        #expect(details.limitReached(in: plan(31 * 60), policy: policy)?.name == "Games")
        #expect(details.limitReached(in: plan(61 * 60), policy: policy)?.name == "Games")
        #expect(details.limitReached(in: plan(10 * 60), policy: policy) == nil)
        // Messages isn't a game: only the all-apps limit reaches it.
        let chat = AppDetails(item: messages, items: items, policy: policy)
        #expect(chat.limitReached(in: plan(31 * 60), policy: policy) == nil)
        #expect(chat.limitReached(in: plan(61 * 60), policy: policy)?.name == "All")
        #expect(AppDetails(item: messages, items: items, policy: policy, exempt: [messages.id])
            .limitReached(in: plan(61 * 60), policy: policy) == nil)
    }

    @Test func usageAddsUpDaysAndAveragesReportedDaysBeforeToday() {
        let details = AppDetails(item: scannedRoblox, items: items, policy: Policy(kidID: kid))
        func sample(_ item: TrackedItem, _ day: DayKey, _ seconds: Double) -> UsageSample {
            let start = day.start(in: utc).addingTimeInterval(3600)
            return UsageSample(id: UUID(), kidID: kid, itemID: item.id, day: day, start: start,
                               end: start.addingTimeInterval(seconds), seconds: seconds)
        }
        // Today 10 min, yesterday 20, 5 days ago 30; 40 days ago is out of range. 10 days ago only Messages: reported.
        var byDay: [DayKey: [UsageSample]] = [:]
        for (back, seconds) in [(0, 600.0), (1, 1200), (5, 1800), (40, 9999)] {
            byDay[testDay.adding(days: -back, calendar: utc), default: []].append(sample(roblox, testDay.adding(days: -back, calendar: utc), seconds))
        }
        byDay[testDay.adding(days: -10, calendar: utc)] = [sample(messages, testDay.adding(days: -10, calendar: utc), 60)]
        let usage = details.usage(today: testDay, calendar: utc) { byDay[$0] ?? [] }
        #expect(usage.days.count == 30 && usage.days.last?.day == testDay)
        #expect(usage.today == 600 && usage.yesterday == 1200)
        #expect(usage.last7Days == 3600 && usage.last30Days == 3600)
        #expect(usage.reportedDays == 3)
        #expect(usage.dailyAverage == 1000)
        #expect(usage.lastUsed == testDay.start(in: utc).addingTimeInterval(3600 + 600))
        #expect(AppDetails.Usage(days: []).dailyAverage == nil)
    }

    @Test func requestsForTheAppOrItsCategoryNewestFirst() {
        let details = AppDetails(item: roblox, items: items, policy: Policy(kidID: kid))
        let limit = UUID()
        let asked = TimeRequest(kidID: kid, itemID: scannedRoblox.id, reason: .limit(limit), minutes: 15, at: at(10, 0))
        let category = TimeRequest(kidID: kid, itemID: scannedGames.id, reason: .limit(limit), minutes: nil, at: at(11, 0))
        let phone = TimeRequest(kidID: kid, itemID: nil, reason: .downtime(UUID()), minutes: 15, at: at(12, 0))
        let old = TimeRequest(kidID: kid, itemID: roblox.id, reason: .blocked, minutes: 15, at: at(-24 * 40, 0))
        let grant = TimeGrant(request: asked, approved: true, minutes: 15, at: at(10, 5), by: "Dad")
        let minute = ExtraMinuteUse(kidID: kid, itemID: roblox.id, reason: .limit(limit), at: at(13, 0), minutes: 1)
        let other = ExtraMinuteUse(kidID: kid, itemID: messages.id, reason: .limit(limit), at: at(14, 0), minutes: 1)
        let result = details.requests([asked, category, phone, old], grants: [grant], extraMinutes: [minute, other],
                                      since: at(-24 * 30, 0))
        #expect(result == [.extraMinute(minute), .asked(category, nil), .asked(asked, grant)])
    }

    @Test func alertRulesForTheApp() {
        let details = AppDetails(item: roblox, items: items, policy: Policy(kidID: kid))
        let own = Rule(kidID: kid, condition: .dailyThreshold(itemID: scannedRoblox.id, minutes: 60))
        let phone = Rule(kidID: kid, condition: .dailyThreshold(itemID: nil, minutes: 60))
        #expect(details.alertRules([own, phone, Rule(kidID: kid, condition: .newApp)]) == [own])
    }
}
