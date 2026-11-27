import Foundation
import Testing
@testable import ThymeCore

struct CheckInsTests {
    let youtube = UUID(), roblox = UUID(), messages = UUID()

    func sample(_ item: UUID, _ start: Date, _ end: Date, _ seconds: Double, reported: Date? = nil) -> UsageSample {
        UsageSample(id: UUID(), kidID: testKid.id, itemID: item, day: testDay, start: start, end: end, seconds: seconds,
                    reportedAt: reported ?? end)
    }

    func coverage(_ result: DayTimeline, at date: Date) -> Coverage? {
        result.coverage.first { $0.start <= date && date < $0.end }?.coverage
    }

    @Test func regularUseIsPlacedAndIdleIsQuiet() {
        let (_, result) = timeline([SyntheticSession(item: youtube, start: at(16, 0), minutes: 30)])
        #expect(coverage(result, at: at(15, 0)) == .quiet)
        #expect(coverage(result, at: at(16, 1)) == .placed)
        #expect(coverage(result, at: at(16, 29)) == .placed)
        #expect(result.blocks.count == 1 && result.blocks.allSatisfy { $0.somewhereIn == nil })
    }

    @Test func aLittleUseBetweenCheckInsIsDropped() {
        // 16 s of Messages since 9:24, reported at 10:25 for the 9 o'clock hour; no wake in between.
        let result = Reconstructor.build(DayInput(dayStart: dayStart, total: [], samples: [
            sample(messages, at(9, 24), at(10, 0), 16, reported: at(10, 25)),
        ]))
        #expect(result.blocks.isEmpty)
        #expect(coverage(result, at: at(9, 30)) == .quiet)
        #expect(result.items[messages]?.seconds == 16)
    }

    @Test func useWithNoWakeIsBlindAndGuessedBackToBack() {
        // 25 min of use in the 5 o'clock hour, and the wake alarm never fired.
        let result = Reconstructor.build(DayInput(dayStart: dayStart, total: [], samples: [
            sample(youtube, at(17, 0), at(18, 0), 900, reported: at(18, 30)),
            sample(roblox, at(17, 0), at(18, 0), 600, reported: at(18, 30)),
        ]))
        #expect(coverage(result, at: at(17, 30)) == .blind)
        let tube = result.blocks.first { $0.itemID == youtube }
        let blox = result.blocks.first { $0.itemID == roblox }
        // The most-used app last, ending with the sample's window; the other just before it.
        #expect(tube?.start == at(17, 45) && tube?.end == at(18, 0))
        #expect(blox?.start == at(17, 35) && blox?.end == at(17, 45))
        #expect(tube?.somewhereIn == DateInterval(start: at(17, 0), end: at(18, 0)))
    }

    @Test func aBurstLosesItsTiming() {
        // An on-time wake at 9:24, then iOS delivers ten minutes' worth at once at 10:25.
        var total = [FirePoint(minute: 80, at: at(9, 22)), FirePoint(minute: 82, at: at(9, 24))]
        total += stride(from: 84, through: 102, by: 2).enumerated().map { index, minute in
            FirePoint(minute: minute, at: at(10, 25, Double(index) * 3))
        }
        let result = Reconstructor.build(DayInput(dayStart: dayStart, total: total, samples: [
            sample(youtube, at(10, 0), at(10, 25, 27), 180),
        ]))
        #expect(coverage(result, at: at(9, 23)) == .placed)
        #expect(coverage(result, at: at(10, 0)) == .burst)
        let block = result.blocks.first
        #expect(block?.somewhereIn != nil && block?.seconds == 180)
        #expect(block?.end == at(10, 25, 27))
    }

    @Test func extraUseBeforeAnOnTimeWakeIsGuessedBeforeIt() {
        // Two minutes placed by the wake at 15:42, but Apple counts five since the previous fetch at 15:00.
        let result = Reconstructor.build(DayInput(dayStart: dayStart, total: [FirePoint(minute: 2, at: at(15, 42))],
                                                  samples: [sample(youtube, at(15, 0), at(15, 42), 300)]))
        let blocks = result.blocks.sorted { $0.start < $1.start }
        #expect(blocks.map(\.start) == [at(15, 37), at(15, 40)])
        #expect(blocks.map(\.seconds) == [180, 120])
        #expect(blocks.first?.somewhereIn != nil && blocks.last?.somewhereIn == nil)
        #expect(coverage(result, at: at(15, 20)) == .blind)
        #expect(coverage(result, at: at(15, 41)) == .placed)
    }

    @Test func websitesDoNotTipAStretchIntoBlind() {
        var input = DayInput(dayStart: dayStart, total: [], samples: [
            sample(youtube, at(9, 0), at(10, 0), 90, reported: at(10, 5)),
            sample(roblox, at(9, 0), at(10, 0), 90, reported: at(10, 5)),
        ])
        #expect(coverage(Reconstructor.build(input), at: at(9, 30)) == .blind)
        input.websites = [roblox]
        #expect(coverage(Reconstructor.build(input), at: at(9, 30)) == .quiet)
    }

    @Test func aWebAppTakesTheSiteWhoseTimeMatchesItsOwn() {
        // A web app for 10 min, its site for about as long, and another site in a browser for 2.
        let webApp = UUID(), site = UUID(), other = UUID(), browser = UUID()
        var input = DayInput(dayStart: dayStart, total: [], samples: [
            sample(webApp, at(17, 0), at(18, 0), 600, reported: at(18, 30)),
            sample(site, at(17, 0), at(18, 0), 580, reported: at(18, 30)),
            sample(other, at(17, 0), at(18, 0), 120, reported: at(18, 30)),
            sample(browser, at(17, 0), at(18, 0), 120, reported: at(18, 30)),
        ])
        input.websites = [site, other]
        input.browsers = [webApp]
        let blocks = Reconstructor.build(input).blocks
        #expect(blocks.first { $0.itemID == webApp }?.site == site)
        #expect(blocks.allSatisfy { $0.itemID == webApp || $0.site == nil })
    }

    @Test func aWebAppKeepsNoSiteWithoutAMatch() {
        // The only site was used for a third as long, and another site's use was in another hour.
        let webApp = UUID(), site = UUID(), later = UUID()
        var input = DayInput(dayStart: dayStart, total: [], samples: [
            sample(webApp, at(17, 0), at(18, 0), 600, reported: at(18, 30)),
            sample(site, at(17, 0), at(18, 0), 200, reported: at(18, 30)),
            sample(later, at(18, 0), at(18, 30), 600, reported: at(18, 30)),
        ])
        input.websites = [site, later]
        input.browsers = [webApp]
        #expect(Reconstructor.build(input).blocks.first { $0.itemID == webApp }?.site == nil)
    }

    @Test func browsersInOneFetchShareItsSites() {
        // Safari for 5 min on one site, Chrome for 2 on another, in the same fetch: each takes its own, though Chrome's
        // 2 minutes would fit inside Safari's site too.
        let safari = UUID(), chrome = UUID(), news = UUID(), game = UUID()
        var input = DayInput(dayStart: dayStart, total: [], samples: [
            sample(safari, at(17, 0), at(18, 0), 300, reported: at(18, 30)),
            sample(news, at(17, 0), at(18, 0), 300, reported: at(18, 30)),
            sample(chrome, at(17, 0), at(18, 0), 120, reported: at(18, 30)),
            sample(game, at(17, 0), at(18, 0), 120, reported: at(18, 30)),
        ])
        input.websites = [news, game]
        input.browsers = [safari, chrome]
        let blocks = Reconstructor.build(input).blocks
        #expect(blocks.first { $0.itemID == safari }?.site == news)
        #expect(blocks.first { $0.itemID == chrome }?.site == game)
    }

    @Test func aBrowsersTimeOnSitesIsTheSites() {
        // Chrome for 10 min, 8 of them on one site; Safari for 3, all on another; an app for 5.
        let chrome = UUID(), safari = UUID(), game = UUID(), news = UUID(), app = UUID()
        var input = DayInput(dayStart: dayStart, total: [], samples: [
            sample(chrome, at(17, 0), at(18, 0), 600, reported: at(18, 30)),
            sample(game, at(17, 0), at(18, 0), 480, reported: at(18, 30)),
            sample(safari, at(18, 0), at(18, 30), 180, reported: at(18, 30)),
            sample(news, at(18, 0), at(18, 30), 180, reported: at(18, 30)),
            sample(app, at(17, 0), at(18, 0), 300, reported: at(18, 30)),
        ])
        input.websites = [game, news]
        input.browsers = [chrome, safari]
        let timeline = Reconstructor.build(input)
        #expect(timeline.attributed.mapValues(\.seconds) == [chrome: 120, game: 480, news: 180, app: 300])
        // Apple's numbers stay as they were.
        #expect(timeline.items[chrome]?.seconds == 600)
        #expect(timeline.items[safari]?.seconds == 180)
        // Places count blocks the same way.
        let seconds = Dictionary(timeline.blocks.map { ($0.itemID, $0.ownSeconds) }, uniquingKeysWith: +)
        #expect(seconds[chrome] == 120)
        #expect(seconds[safari] == 0)
    }

    @Test func aSitesTimeInsideAnotherAppIsTheApps() {
        // A game for 50 min with an ad's site on screen for 48 of them; Safari for 5 on a news site plus 1 on the
        // ad's site, in the same fetch. Safari takes its 6 minutes of sites; the ad's other 47 were inside the game.
        let game = UUID(), ad = UUID(), safari = UUID(), news = UUID()
        var input = DayInput(dayStart: dayStart, total: [], samples: [
            sample(game, at(17, 0), at(18, 0), 3000, reported: at(18, 30)),
            sample(ad, at(17, 0), at(18, 0), 2880, reported: at(18, 30)),
            sample(safari, at(17, 0), at(18, 0), 360, reported: at(18, 30)),
            sample(news, at(17, 0), at(18, 0), 300, reported: at(18, 30)),
        ])
        input.websites = [ad, news]
        input.browsers = [safari]
        let timeline = Reconstructor.build(input)
        #expect(timeline.attributed.mapValues(\.seconds) == [game: 3000, ad: 60, news: 300])
        // Apple's numbers stay as they were.
        #expect(timeline.items[ad]?.seconds == 2880)
        // Blocks (and so places) count the same way.
        let seconds = Dictionary(timeline.blocks.map { ($0.itemID, $0.ownSeconds) }, uniquingKeysWith: +)
        #expect(seconds[game] == 3000)
        #expect(seconds[ad] == 60)
        #expect(seconds[news] == 300)
    }

    @Test func aBrowserTakesTheSiteThatMatchesItsTimeOverAdsThatFit() {
        // A web app for 300 s on its site, which Apple gives 303 s; two ads in a game beside it, 120 s each. Both ads
        // fit in the web app's time and its site doesn't, but the site is the match: the ads were the game's.
        let webApp = UUID(), site = UUID(), game = UUID(), ad1 = UUID(), ad2 = UUID()
        var input = DayInput(dayStart: dayStart, total: [], samples: [
            sample(webApp, at(17, 0), at(18, 0), 300, reported: at(18, 30)),
            sample(site, at(17, 0), at(18, 0), 303, reported: at(18, 30)),
            sample(game, at(17, 0), at(18, 0), 400, reported: at(18, 30)),
            sample(ad1, at(17, 0), at(18, 0), 120, reported: at(18, 30)),
            sample(ad2, at(17, 0), at(18, 0), 120, reported: at(18, 30)),
        ])
        input.websites = [site, ad1, ad2]
        input.browsers = [webApp]
        let timeline = Reconstructor.build(input)
        #expect(timeline.attributed.mapValues(\.seconds) == [site: 300, game: 400])
        #expect(timeline.blocks.allSatisfy { [webApp, site, game].contains($0.itemID) })
        #expect(timeline.blocks.first { $0.itemID == webApp }?.site == site)
    }

    @Test func iOSSheetsOverAnAppAreGone() {
        // Photos for 100 s with the Face ID prompt over it for 3 of them; Apple counts the prompt on top.
        let photos = UUID(), prompt = UUID()
        var input = DayInput(dayStart: dayStart, total: [], samples: [
            sample(photos, at(17, 0), at(18, 0), 100, reported: at(18, 30)),
            sample(prompt, at(17, 0), at(18, 0), 3, reported: at(18, 30)),
        ])
        input.overlays = [prompt]
        let timeline = Reconstructor.build(input)
        #expect(timeline.attributed.mapValues(\.seconds) == [photos: 100])
        #expect(timeline.blocks.allSatisfy { $0.itemID == photos })
        // Apple's numbers stay as they were.
        #expect(timeline.items[prompt]?.seconds == 3)
    }

    @Test func aSiteSeenOnlyInsideAppsIsGone() {
        // An ad's site in a game, with no browser used at all.
        let game = UUID(), ad = UUID()
        var input = DayInput(dayStart: dayStart, total: [], samples: [
            sample(game, at(17, 0), at(18, 0), 600, reported: at(18, 30)),
            sample(ad, at(17, 0), at(18, 0), 590, reported: at(18, 30)),
        ])
        input.websites = [ad]
        let timeline = Reconstructor.build(input)
        #expect(timeline.attributed.mapValues(\.seconds) == [game: 600])
        #expect(timeline.blocks.allSatisfy { $0.itemID == game })
    }

    @Test func browsersAreKnownByBundleID() {
        #expect(BuiltInApps.showsWebsites("com.google.chrome.ios"))
        #expect(BuiltInApps.showsWebsites("com.apple.mobilesafari"))
        #expect(BuiltInApps.showsWebsites(BuiltInApps.webApp))
        #expect(!BuiltInApps.showsWebsites("com.amazon.Amazon"))
    }
}
