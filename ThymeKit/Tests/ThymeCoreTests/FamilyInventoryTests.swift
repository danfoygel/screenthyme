import Foundation
import Testing
@testable import ThymeCore

struct FamilyInventoryTests {
    let kid = UUID()

    func entry(_ identifier: String, _ kind: ItemKind = .app, token: UInt8) -> FamilyInventory.Entry {
        FamilyInventory.Entry(kind: kind, identifier: identifier, tokenData: Data([token]))
    }

    func data(_ identifier: String, _ kind: ItemKind = .app) -> TrackedItem {
        TrackedItem(kidID: kid, kind: kind, identifier: identifier, firstSeen: Date())
    }

    func scanned(token: UInt8, _ kind: ItemKind = .app) -> TrackedItem {
        TrackedItem(kidID: kid, kind: kind, identifier: TrackedItem.scannedIdentifier(tokenData: Data([token])),
                    tokenData: Data([token]), firstSeen: Date())
    }

    @Test func entriesBecomeScannedItemsMatchedToApplesItems() throws {
        let app = data("com.example.game")
        var items = [app]
        let outcome = FamilyInventory.apply([entry("com.example.game", token: 1)], to: &items, kid: kid)
        let made = try #require(items.first { $0.isScanned })
        #expect(made.tokenData == Data([1]))
        #expect(made.match == app.id)
        #expect(outcome.tokens == 1)
        #expect(outcome.pairing.added == 1)
        #expect(Set(outcome.changed.map(\.id)) == [made.id])
    }

    /// The same token as the scan's finds the scan's item: nothing new, only its match.
    @Test func aScannedTokenGetsItsMatch() {
        let app = data("com.example.game")
        let scan = scanned(token: 1)
        var items = [app, scan]
        let outcome = FamilyInventory.apply([entry("com.example.game", token: 1)], to: &items, kid: kid)
        #expect(items.count == 2)
        #expect(items.first { $0.id == scan.id }?.match == app.id)
        #expect(outcome.tokens == 0)
        #expect(outcome.changed.map(\.id) == [scan.id])
    }

    @Test func listingAgainChangesNothing() {
        var items = [data("com.example.game"), data("example.com", .domain), data("Games", .category)]
        let entries = [entry("com.example.game", token: 1), entry("example.com", .domain, token: 2),
                       entry("Games", .category, token: 3)]
        _ = FamilyInventory.apply(entries, to: &items, kid: kid)
        let before = items
        let again = FamilyInventory.apply(entries, to: &items, kid: kid)
        #expect(again.changed.isEmpty)
        #expect(again.pairing.unchanged == 3)
        #expect(items == before)
    }

    /// One a scan dropped gets its token back and keeps its match.
    @Test func aDroppedTokenComesBack() {
        let app = data("com.example.game")
        var dropped = scanned(token: 1)
        dropped.tokenData = nil
        dropped.match = app.id
        var items = [app, dropped]
        let outcome = FamilyInventory.apply([entry("com.example.game", token: 1)], to: &items, kid: kid)
        let item = items.first { $0.id == dropped.id }
        #expect(item?.tokenData == Data([1]))
        #expect(item?.match == app.id)
        #expect(outcome.tokens == 1)
    }

    /// Sites and apps Apple's usage data hasn't shown on this phone get a bare item, as matching makes.
    @Test func unseenItemsAreCreated() {
        var items: [TrackedItem] = []
        let outcome = FamilyInventory.apply([entry("example.com", .domain, token: 2)], to: &items, kid: kid)
        let site = items.first { !$0.isScanned }
        #expect(site?.identifier == "example.com")
        #expect(items.first { $0.isScanned }?.match == site?.id)
        #expect(outcome.pairing.created == 1)
        #expect(outcome.changed.count == 2)
    }

    @Test func categoriesMatchByName() {
        let games = data("Games", .category)
        var items = [games]
        _ = FamilyInventory.apply([entry("Games", .category, token: 3)], to: &items, kid: kid)
        #expect(items.first { $0.isScanned }?.match == games.id)
        #expect(items.first { $0.isScanned }?.kind == .category)
    }

    @Test func tokensItDoesNotListAreKept() {
        let other = scanned(token: 9)
        var items = [other]
        _ = FamilyInventory.apply([entry("com.example.game", token: 1)], to: &items, kid: kid)
        #expect(items.first { $0.id == other.id }?.tokenData == Data([9]))
    }

    @Test func entriesWithoutANameAreSkipped() {
        var items: [TrackedItem] = []
        let outcome = FamilyInventory.apply([entry("", token: 1)], to: &items, kid: kid)
        #expect(items.isEmpty)
        #expect(outcome.changed.isEmpty)
    }
}
