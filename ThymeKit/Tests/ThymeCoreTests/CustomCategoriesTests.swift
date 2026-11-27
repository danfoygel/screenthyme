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

    /// A second kid's copy of `item`'s app or website.
    func sibling(_ item: TrackedItem, kid: UUID) -> TrackedItem {
        TrackedItem(kidID: kid, kind: item.kind, identifier: item.identifier, category: item.category, firstSeen: dayStart)
    }

    @Test func movesAreTheFamilys() {
        let twin = UUID()
        let siblingSite = sibling(site, kid: twin), siblingRoblox = sibling(roblox, kid: twin)
        let siblingItems = Dictionary(uniqueKeysWithValues: [siblingSite, siblingRoblox, sibling(other, kid: twin)]
            .map { ($0.id, $0) })
        let all = items.merging(siblingItems) { a, _ in a }
        let siblingPolicy = Policy(kidID: twin).withCustomCategories(items: siblingItems)

        // Moved for one kid, the same website moves for the other, into a Games category their phone hasn't seen yet.
        let moves = FamilyCategoryMoves(policies: [movedPolicy(), siblingPolicy], items: all)
        #expect(moves.category(of: siblingSite) == "Games")
        #expect(moves.category(of: siblingRoblox) == nil)
        let shared = siblingPolicy.withFamilyMoves(moves, items: siblingItems)
        let siblingGames = Policy.categoryGroupID(kid: twin, category: "Games")
        #expect(shared.groups.first { $0.id == siblingGames }?.moved == [siblingSite.id])
        #expect(CustomCategories(policy: shared, items: siblingItems).categoryName(of: siblingSite) == "Games")
        // Twice changes nothing; once their phone sees Games, set-up fills its items and keeps the move.
        #expect(shared.withFamilyMoves(moves, items: siblingItems) == shared)
        let siblingGamesItem = sibling(games, kid: twin)
        let seen = shared.withCustomCategories(items: siblingItems.merging([siblingGamesItem.id: siblingGamesItem]) { a, _ in a })
        #expect(seen.groups.first { $0.id == siblingGames }?.items == [siblingGamesItem.id])
        #expect(seen.groups.first { $0.id == siblingGames }?.moved == [siblingSite.id])

        // Moving it back, from either kid, moves it back for both.
        var back = moves
        back.move(siblingSite, to: "Other")
        #expect(back.categories.isEmpty)
        #expect(shared.withFamilyMoves(back, items: siblingItems).groups.allSatisfy { $0.moved.isEmpty })
        #expect(movedPolicy().withFamilyMoves(back, items: items).groups.allSatisfy { $0.moved.isEmpty })
    }

    @Test func disagreeingMovesGoToTheNewestPolicy() {
        let twin = UUID()
        let siblingSite = sibling(site, kid: twin)
        let siblingItems = [siblingSite.id: siblingSite]
        var mine = movedPolicy()
        mine.updatedAt = dayStart
        var theirs = Policy(kidID: twin, updatedAt: dayStart.addingTimeInterval(60))
        theirs.groups = [ItemGroup(id: Policy.categoryGroupID(kid: twin, category: "Education"), name: "Education",
                               category: "Education", moved: [siblingSite.id])]
        let all = items.merging(siblingItems) { a, _ in a }
        #expect(FamilyCategoryMoves(policies: [mine, theirs], items: all).category(of: site) == "Education")
        mine.updatedAt = dayStart.addingTimeInterval(120)
        #expect(FamilyCategoryMoves(policies: [mine, theirs], items: all).category(of: site) == "Games")
        // Scanned items and categories never move between kids.
        #expect(FamilyCategoryMoves(policies: [mine], items: all).category(of: scannedSite) == nil)
    }
}
