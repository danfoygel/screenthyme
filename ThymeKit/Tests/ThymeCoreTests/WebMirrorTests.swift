import Foundation
import Testing
@testable import ThymeCore

struct WebMirrorTests {
    let kid = UUID()
    let today = DayKey(Date(timeIntervalSince1970: 1_800_000_000))

    func app(_ identifier: String) -> TrackedItem {
        TrackedItem(kidID: kid, kind: .app, identifier: identifier, firstSeen: today.start())
    }

    /// A fetch's sample of `item`, `minute` minutes into the day, two minutes long.
    func sample(_ item: TrackedItem, _ seconds: Double, minute: Int, day: DayKey? = nil) -> UsageSample {
        let day = day ?? today
        let start = day.start().addingTimeInterval(Double(minute) * 60)
        return UsageSample(id: UUID(), kidID: kid, itemID: item.id, day: day, start: start,
                           end: start.addingTimeInterval(120), seconds: seconds)
    }

    /// Depop's minutes were Safari's (the shop's website); Reddit's were its own; Photos is matched to the scan.
    @Test func appsInsideSafarisTimeAreItsWebsites() {
        let safari = app(WebMirror.browser)
        let depop = app("com.garageitaly.garage")
        let reddit = app("com.reddit.Reddit")
        let photos = app("com.apple.mobileslideshow")
        var scanned = TrackedItem(kidID: kid, kind: .app, identifier: TrackedItem.scannedPrefix + "p", tokenData: Data([1]),
                                  firstSeen: today.start())
        scanned.match = photos.id
        let items = Dictionary(uniqueKeysWithValues: [safari, depop, reddit, photos, scanned].map { ($0.id, $0) })

        var mirror = WebMirror()
        mirror.add([sample(safari, 119.1, minute: 0), sample(depop, 119.1, minute: 0),
                    sample(safari, 60, minute: 2), sample(depop, 31.6, minute: 2),
                    sample(reddit, 110, minute: 4), sample(safari, 5, minute: 4),
                    sample(safari, 30, minute: 6), sample(photos, 10, minute: 6)], items: items)

        #expect(mirror.mirrored(items: items, today: today) == [depop.id])
    }

    @Test func aFewUncoveredSecondsAreSlack() {
        let safari = app(WebMirror.browser)
        let amazon = app("com.amazon.Amazon")
        let items = Dictionary(uniqueKeysWithValues: [safari, amazon].map { ($0.id, $0) })
        var mirror = WebMirror()
        // Within a second and a half, then 5 s with no Safari in that interval: 96% inside.
        mirror.add([sample(safari, 79, minute: 0), sample(amazon, 80, minute: 0),
                    sample(safari, 40, minute: 2), sample(amazon, 31, minute: 2), sample(amazon, 5, minute: 4)], items: items)
        #expect(mirror.mirrored(items: items, today: today) == [amazon.id])

        // A real app used on its own a tenth of the time is an app.
        mirror.add([sample(amazon, 20, minute: 6)], items: items)
        #expect(mirror.mirrored(items: items, today: today).isEmpty)
    }

    @Test func onlyTheLastWeekCounts() throws {
        let safari = app(WebMirror.browser)
        let shop = app("com.example.shop")
        let items = Dictionary(uniqueKeysWithValues: [safari, shop].map { ($0.id, $0) })
        let old = today.adding(days: -WebMirror.days)
        var mirror = WebMirror()
        // Installed since: used on its own today, after a week and more of its website.
        mirror.add([sample(safari, 100, minute: 0, day: old), sample(shop, 100, minute: 0, day: old),
                    sample(shop, 60, minute: 0)], items: items)
        #expect(mirror.mirrored(items: items, today: today.adding(days: -1)) == [shop.id])
        #expect(mirror.mirrored(items: items, today: today).isEmpty)

        mirror.prune(today: today)
        #expect(mirror.byDay.keys.sorted() == [today])
        let decoded = try JSONDecoder().decode(WebMirror.self, from: JSONEncoder().encode(mirror))
        #expect(decoded == mirror)
    }

    /// Exempt from all-apps limits, like ScreenThyme: Safari already counts the time.
    @Test func allAppsTotalsLeaveMirroredAppsOut() {
        let safari = app(WebMirror.browser)
        let depop = app("com.garageitaly.garage")
        let items = Dictionary(uniqueKeysWithValues: [safari, depop].map { ($0.id, $0) })
        let usage = [safari.id: 600.0, depop.id: 500.0]
        #expect(EnforcementPlanner.totalSeconds(items: items, usage: usage) == 1100)
        #expect(EnforcementPlanner.totalSeconds(items: items, usage: usage, excluding: [depop.id]) == 600)
    }
}
