import Foundation
import Testing
@testable import ThymeCore

/// Custom categories (PLAN.md §15.14): Apple's categories as groups, with apps and websites moved between them.
struct CustomCategoriesTests {
    let kid = testKid.id

    func item(_ kind: ItemKind, _ identifier: String, category: String? = nil) -> TrackedItem {
        TrackedItem(kidID: testKid.id, kind: kind, identifier: identifier, category: category, firstSeen: dayStart)
    }

    func scanned(_ kind: ItemKind, _ name: String, match: TrackedItem) -> TrackedItem {
        var item = TrackedItem(kidID: testKid.id, kind: kind, identifier: TrackedItem.scannedPrefix + name,
                               tokenData: Data(name.utf8), firstSeen: dayStart)
        item.match = match.id
        return item
    }

    var games: TrackedItem { item(.category, "Games") }
    var other: TrackedItem { item(.category, "Other") }
    var roblox: TrackedItem { item(.app, "com.roblox.robloxmobile", category: "Games") }
    var site: TrackedItem { item(.domain, "realenginesimulator.com", category: "Other") }
    var maps: TrackedItem { item(.domain, "maps.example.com", category: "Other") }
    var scannedGames: TrackedItem { scanned(.category, "games", match: games) }
    var scannedOther: TrackedItem { scanned(.category, "other", match: other) }
    var scannedSite: TrackedItem { scanned(.domain, "site", match: site) }

    var items: [UUID: TrackedItem] {
        Dictionary(uniqueKeysWithValues: [games, other, roblox, site, maps, scannedGames, scannedOther, scannedSite]
            .map { ($0.id, $0) })
    }

    var gamesID: UUID { Policy.categoryGroupID(kid: kid, category: "Games") }
    var otherID: UUID { Policy.categoryGroupID(kid: kid, category: "Other") }

    /// A policy with a limit on each of Apple's categories (as scanned items, which hold tokens), set up and with the
    /// website moved from Other to Games.
    func movedPolicy() -> Policy {
        let policy = Policy(kidID: kid, limits: [
            AppLimit(name: "Games", items: [scannedGames.id], minutes: 60),
            AppLimit(name: "Other", items: [scannedOther.id], minutes: 30),
        ])
        var moved = policy.withCustomCategories(items: items)
        moved.move(site.id, to: gamesID, items: items)
        return moved
    }

    @Test func settingUpMakesAGroupPerCategoryAndConvertsItsUses() {
        let policy = Policy(kidID: kid, alwaysAllowed: [scannedOther.id, roblox.id], uncounted: [scannedOther.id],
                            limits: [AppLimit(name: "Games", items: [scannedGames.id, roblox.id], minutes: 60)],
                            groups: [ItemGroup(name: "Fun", items: [scannedGames.id])])
        let set = policy.withCustomCategories(items: items)
        let categories = set.groups.filter(\.isCategory)
        #expect(categories.map(\.name) == ["Games", "Other"])
        #expect(categories.first { $0.id == gamesID }?.items == [games.id, scannedGames.id])
        #expect(set.limits[0].items == [gamesID, roblox.id])
        #expect(set.alwaysAllowed == [otherID, roblox.id])
        #expect(set.uncounted == [otherID])
        // The parents' own groups keep Apple's categories: groups don't nest.
        #expect(set.groups.first { $0.name == "Fun" }?.items == [scannedGames.id])
        // Twice changes nothing, and another phone gets the same ids.
        #expect(set.withCustomCategories(items: items) == set)
        #expect(PolicyEdit.between(policy, set).contains(.categoriesAdded(["Games", "Other"])))
    }

    @Test func movingAndMovingBack() {
        var policy = movedPolicy()
        #expect(policy.groups.first { $0.id == gamesID }?.moved == [site.id])
        let custom = CustomCategories(policy: policy, items: items)
        // The scanned website follows its match.
        #expect(custom.moved[scannedSite.id]?.id == gamesID)
        #expect(custom.categoryName(of: site) == "Games")
        #expect(custom.group(of: maps)?.id == otherID)
        #expect(custom.movedOut(of: ["Other"], items: items) == [site.id, scannedSite.id])
        #expect(custom.movedOut(of: ["Games"], items: items).isEmpty)

        // Moving it to Other, Apple's own category for it, is moving it back.
        policy.move(site.id, to: otherID, items: items)
        #expect(policy.groups.allSatisfy { $0.moved.isEmpty })
    }

    @Test func aMoveIsInTheChangeHistory() {
        let before = Policy(kidID: kid).withCustomCategories(items: items)
        var after = before
        after.move(site.id, to: gamesID, items: items)
        let edits = PolicyEdit.between(before, after)
        #expect(edits == [.categoryMove(item: site.id, from: nil, to: gamesID)])
        let names = [site.id: "realenginesimulator.com", gamesID: "Games"]
        let line = edits[0].describe { names[$0] ?? "?" }
        #expect(line.title == "Moved realenginesimulator.com to Games")
        #expect(line.details == ["From Apple's category"])
        #expect(PolicyEdit.between(after, before) == [.categoryMove(item: site.id, from: gamesID, to: nil)])
    }

    @Test func limitsCountAndShieldByCustomCategory() {
        let policy = movedPolicy()
        let usage = [site.id: 40 * 60.0, maps.id: 10 * 60.0, roblox.id: 30 * 60.0]
        let plan = EnforcementPlanner.plan(policy: policy, items: items, usage: usage,
                                           state: EnforcementDayState(day: testDay), now: at(12, 0), calendar: utc)
        let games = policy.limits[0], other = policy.limits[1]
        // The website counts toward Games, not Other.
        #expect(plan.used[games.id] == 70)
        #expect(plan.used[other.id] == 10)
        // Games is used up: its category and the website's token are shielded.
        #expect(plan.exhaustedLimits == [games.id])
        #expect(plan.limitedItems.isSuperset(of: [scannedGames.id, scannedSite.id]))
        // iOS's event for Other would count the website: Other gets none. Games' event names its token.
        let resolved = policy.resolved(items: items)
        #expect(EnforcementPlanner.eventMiscounts(resolved.limits[1], policy: resolved, items: items))
        #expect(!EnforcementPlanner.eventMiscounts(resolved.limits[0], policy: resolved, items: items))
        #expect(resolved.limits[0].items.contains(scannedSite.id))
    }

    @Test func appleCategoriesNamedElsewhereStandForTheCustomOnes() {
        var policy = movedPolicy()
        policy.blocked = [scannedGames.id]
        #expect(policy.resolved(items: items).blocked.isSuperset(of: [scannedGames.id, site.id, scannedSite.id]))
    }

    @Test func detailsGiveTheCustomCategory() {
        let policy = movedPolicy()
        let details = AppDetails(item: site, items: items, policy: policy)
        #expect(details.categoryName == "Games")
        #expect(details.limits.map(\.limit.name) == ["Games"])
    }
}
