import Foundation
import Testing
@testable import ThymeCore

struct CategoryUsageTests {
    let kid = UUID()
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func item(_ kind: ItemKind, _ identifier: String, category: String? = nil) -> TrackedItem {
        TrackedItem(kidID: kid, kind: kind, identifier: identifier, category: category, firstSeen: start)
    }

    func use(_ seconds: Double) -> ItemUsage {
        ItemUsage(seconds: seconds, firstAt: start, lastAt: start.addingTimeInterval(seconds))
    }

    /// Apps add up under their category, most used first; websites and apps that were Safari's on their website don't.
    @Test func appsAddUpByCategory() {
        let roblox = item(.app, "com.roblox.robloxmobile", category: "Games")
        let chess = item(.app, "com.chess.iphone", category: "Games")
        let tiktok = item(.app, "com.zhiliaoapp.musically", category: "Social")
        let depop = item(.app, "com.garageitaly.garage", category: "Shopping & Food")
        let site = item(.domain, "www.youtube.com", category: "Entertainment")
        let unknown = item(.app, "com.example.new")
        let items = Dictionary(uniqueKeysWithValues: [roblox, chess, tiktok, depop, site, unknown].map { ($0.id, $0) })
        let usage = [roblox.id: use(1800), chess.id: use(600), tiktok.id: use(1500), depop.id: use(300),
                     site.id: use(900), unknown.id: use(120)]

        let categories = CategoryUsage.build(usage, items: items, excluding: [depop.id])

        #expect(categories.map(\.name) == ["Games", "Social", nil])
        #expect(categories.map(\.minutes) == [40, 25, 2])
        #expect(categories[0].apps.map(\.id) == [roblox.id, chess.id])
        let total: Double = categories.reduce(0) { $0 + $1.seconds }
        #expect(total == 4020)
    }

    /// Equal totals keep a steady order, by name; an app with no item (not yet synced) counts as uncategorized.
    @Test func tiesSortByName() {
        let notes = item(.app, "com.apple.mobilenotes", category: "Productivity & Finance")
        let books = item(.app, "com.apple.iBooks", category: "Information & Reading")
        let items = Dictionary(uniqueKeysWithValues: [notes, books].map { ($0.id, $0) })
        let missing = UUID()

        let categories = CategoryUsage.build([notes.id: use(60), books.id: use(60), missing: use(30)], items: items)

        #expect(categories.map(\.name) == ["Information & Reading", "Productivity & Finance", nil])
        #expect(categories[2].apps.map(\.id) == [missing])
    }
}
