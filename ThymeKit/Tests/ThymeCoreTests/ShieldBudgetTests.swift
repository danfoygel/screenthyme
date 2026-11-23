import Foundation
import Testing
@testable import ThymeCore

struct ShieldBudgetTests {
    func app(_ n: Int) -> TrackedItem {
        TrackedItem(kidID: testKid.id, kind: .app, identifier: "com.example.app\(n)", firstSeen: dayStart)
    }

    func site(_ n: Int) -> TrackedItem {
        TrackedItem(kidID: testKid.id, kind: .domain, identifier: "site\(n).example.com", firstSeen: dayStart)
    }

    func scanned(_ n: Int, match: TrackedItem) -> TrackedItem {
        var item = TrackedItem(kidID: testKid.id, kind: .app, identifier: "token:\(n)", tokenData: Data([UInt8(n % 256)]),
                               firstSeen: dayStart)
        item.match = match.id
        return item
    }

    func index(_ items: [TrackedItem]) -> [UUID: TrackedItem] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    }

    @Test func underTheCapEverythingIsShielded() {
        let apps = (0..<50).map(app)
        let fitted = ShieldBudget.fit([[], [], Set(apps.map(\.id))], items: index(apps), use: [:])
        #expect(fitted.lists[2] == Set(apps.map(\.id)))
        #expect(fitted.left.isEmpty)
    }

    @Test func overTheCapTheMostRecentlyUsedAreShielded() {
        let apps = (0..<108).map(app)
        // App 100 was used this hour, 101 an hour earlier but longer, 102 this hour for less time than 100.
        let use: [UUID: ShieldBudget.Use] = [
            apps[100].id: .init(lastHour: at(17, 0), seconds: 3 * 3600),
            apps[101].id: .init(lastHour: at(16, 0), seconds: 4 * 3600),
            apps[102].id: .init(lastHour: at(17, 0), seconds: 60),
        ]
        let fitted = ShieldBudget.fit([[], [], Set(apps.map(\.id))], items: index(apps), use: use, cap: 2)
        #expect(fitted.lists[2] == [apps[100].id, apps[102].id])
        #expect(fitted.left.count == 106)
        #expect(fitted.left.contains(apps[101].id))
    }

    @Test func theCapIsForAllListsTogether() {
        let apps = (0..<60).map(app)
        let blocked = Set(apps[0..<20].map(\.id))
        let limited = Set(apps[20..<60].map(\.id))
        let fitted = ShieldBudget.fit([blocked, [], limited], items: index(apps), use: [:])
        // With no use, earlier lists come first.
        #expect(fitted.lists[0] == blocked)
        #expect(fitted.lists[2].count == 30)
        #expect(fitted.left.count == 10)
    }

    @Test func anItemInTwoListsTakesOneSlot() {
        let apps = (0..<3).map(app)
        let fitted = ShieldBudget.fit([[apps[0].id], [], Set(apps.map(\.id))], items: index(apps), use: [:], cap: 3)
        #expect(fitted.lists[0] == [apps[0].id])
        #expect(fitted.lists[2] == [apps[1].id, apps[2].id])
        #expect(fitted.left.isEmpty)
    }

    @Test func websitesHaveTheirOwnCapAndCategoriesNone() {
        let apps = (0..<3).map(app)
        let sites = (0..<3).map(site)
        let games = TrackedItem(kidID: testKid.id, kind: .category, identifier: "Games", firstSeen: dayStart)
        let all = Set((apps + sites + [games]).map(\.id))
        let fitted = ShieldBudget.fit([[], [], all], items: index(apps + sites + [games]), use: [:], cap: 2)
        #expect(fitted.lists[2].count == 5)
        #expect(fitted.lists[2].contains(games.id))
        #expect(fitted.left.count == 2)
    }

    @Test func aScannedAppGoesByItsMatchsUse() {
        let netflix = app(1)
        let tokens = (0..<3).map { scanned($0, match: app(10 + $0)) }
        let netflixToken = scanned(9, match: netflix)
        let use: [UUID: ShieldBudget.Use] = [netflix.id: .init(lastHour: at(17, 0), seconds: 600)]
        let fitted = ShieldBudget.fit([[], [], Set((tokens + [netflixToken]).map(\.id))],
                                      items: index(tokens + [netflixToken, netflix]), use: use, cap: 1)
        #expect(fitted.lists[2] == [netflixToken.id])
    }
}
