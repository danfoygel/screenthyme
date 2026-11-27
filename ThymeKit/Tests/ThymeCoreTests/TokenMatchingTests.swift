import Foundation
import Testing
@testable import ThymeCore

struct TokenMatchingTests {
    let kid = UUID()

    func scanned(_ hash: String, _ kind: ItemKind = .app) -> TrackedItem {
        TrackedItem(kidID: kid, kind: kind, identifier: TrackedItem.scannedPrefix + hash, tokenData: Data([1]),
                    firstSeen: Date())
    }

    func data(_ identifier: String, _ kind: ItemKind = .app) -> TrackedItem {
        TrackedItem(kidID: kid, kind: kind, identifier: identifier, firstSeen: Date())
    }

    @Test func applyMatchesCorrectsAndSkipsUnknown() {
        let new = scanned("new")
        var wrong = scanned("wrong")
        wrong.match = TrackedItem.id(kid: kid, kind: .app, identifier: "com.other")
        var right = scanned("right")
        right.match = TrackedItem.id(kid: kid, kind: .app, identifier: "com.right")
        var items = [new, wrong, right, data("com.new"), data("com.wrong"), data("com.right")]

        let outcome = TokenMatching.apply([.init(scanned: new.id, kind: .app, identifier: "com.new"),
                                          .init(scanned: wrong.id, kind: .app, identifier: "com.wrong"),
                                          .init(scanned: right.id, kind: .app, identifier: "com.right"),
                                          .init(scanned: UUID(), kind: .app, identifier: "com.x"),
                                          .init(scanned: new.id, kind: .domain, identifier: "x.com")],
                                         to: &items, kid: kid)

        #expect(outcome.added == 1)
        #expect(outcome.corrected == 1)
        #expect(outcome.unchanged == 1)
        #expect(outcome.unknown == 2)
        #expect(outcome.changed.map(\.id) == [new.id, wrong.id])
        #expect(items[0].match == TrackedItem.id(kid: kid, kind: .app, identifier: "com.new"))
        #expect(items[1].match == TrackedItem.id(kid: kid, kind: .app, identifier: "com.wrong"))
    }

    @Test func appsThePhoneHasNotSeenAreCreated() {
        let app = scanned("app")
        var site = scanned("site", .domain)
        site.match = TrackedItem.id(kid: kid, kind: .domain, identifier: "old.example.com")  // right, but never seen
        let seen = data("com.seen")
        var items = [app, site, seen]
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let outcome = TokenMatching.apply([.init(scanned: app.id, kind: .app, identifier: "com.seen"),
                                          .init(scanned: site.id, kind: .domain, identifier: "old.example.com")],
                                         to: &items, kid: kid, now: now)

        #expect(outcome.created == 1)
        #expect(outcome.unchanged == 1)
        let created = try? #require(items.first { $0.identifier == "old.example.com" })
        #expect(created?.id == site.match)
        #expect(created?.kind == .domain)
        #expect(created?.firstSeen == now)
        #expect(created?.isScanned == false)
        #expect(Set(outcome.changed.map(\.id)) == [app.id, site.match!])
    }

    @Test func newUnmatchedAppsAreToMatch() {
        let lastImport = Date(timeIntervalSince1970: 1_800_000_000)
        func seen(_ identifier: String, _ kind: ItemKind = .app, after: Bool) -> TrackedItem {
            TrackedItem(kidID: kid, kind: kind, identifier: identifier, firstSeen: lastImport.addingTimeInterval(after ? 60 : -60))
        }
        let old = seen("com.old", after: false)
        let new = seen("com.new", after: true)
        let newMatched = seen("com.matched", after: true)
        let site = seen("new.example.com", .domain, after: true)
        let screenshot = seen("com.apple.ScreenshotServicesService", after: true)
        let settings = seen("com.apple.Preferences", after: false)  // unblockable: no token would block it
        let webApps = seen(BuiltInApps.webApp, after: false)
        var scannedApp = scanned("s")
        scannedApp.firstSeen = lastImport.addingTimeInterval(-120)
        scannedApp.match = newMatched.id
        let items = [old, new, newMatched, site, screenshot, settings, webApps, scannedApp]

        let unmatched = TokenMatching.unmatched(items, lastImport: lastImport)
        #expect(unmatched.toMatch.map(\.identifier) == ["com.new"])
        // The last import saw it and didn't match it: the scan hasn't added it.
        #expect(unmatched.toScan.map(\.identifier) == ["com.old"])
        #expect(TokenMatching.unmatched(items, lastImport: nil).toMatch.map(\.identifier) == ["com.old", "com.new"])
        #expect(TokenMatching.unmatched(items, lastImport: nil).toScan.isEmpty)
        // Only the apps used lately.
        #expect(TokenMatching.unmatched(items, lastImport: lastImport, used: [new.id]).toScan.isEmpty)

        // A scan since the last import adds a token: the next import may match every app.
        var rescanned = scanned("r")
        rescanned.firstSeen = lastImport.addingTimeInterval(120)
        let afterScan = TokenMatching.unmatched(items + [rescanned], lastImport: lastImport)
        #expect(afterScan.toMatch.map(\.identifier) == ["com.old", "com.new"])
        #expect(afterScan.toScan.isEmpty)
    }

    @Test func systemProcessesAreTold() {
        #expect(BuiltInApps.isSystemProcess("com.apple.ScreenshotServicesService"))
        #expect(BuiltInApps.isSystemProcess("com.apple.InCallService"))
        #expect(BuiltInApps.isSystemProcess("com.apple.CoreAuthUI"))
        #expect(BuiltInApps.isSystemProcess("com.apple.springboard"))
        #expect(BuiltInApps.isSystemProcess("com.apple.printcenter"))
        #expect(BuiltInApps.isSystemProcess("com.apple.ServicesPaymentAngel"))
        #expect(BuiltInApps.isSystemProcess("com.apple.CoreServicesUIAgent"))
        #expect(BuiltInApps.isSystemProcess("com.apple.SOSBuddy"))
        #expect(BuiltInApps.isSystemProcess("com.apple.ContactsUI.LimitedAccessPromptView"))
        #expect(BuiltInApps.isSystemProcess("com.apple.BusinessActionSheet"))
        #expect(!BuiltInApps.isSystemProcess("com.apple.findmy"))
        #expect(!BuiltInApps.isSystemProcess("com.apple.Preview"))
        #expect(!BuiltInApps.isSystemProcess("com.apple.DocumentsApp"))
        #expect(!BuiltInApps.isSystemProcess(BuiltInApps.webApp))
        #expect(!BuiltInApps.isSystemProcess("com.apple.mobilesafari"))
        #expect(!BuiltInApps.isSystemProcess("com.apple.Pages"))
        #expect(!BuiltInApps.isSystemProcess("com.uo.StoreLocator"))
        #expect(!BuiltInApps.isSystemProcess("com.example.PushService"))
    }

    @Test func sheetsOverAnAppAreTold() {
        #expect(BuiltInApps.isOverlay("com.apple.LocalAuthenticationUIService"))
        #expect(BuiltInApps.isOverlay("com.apple.ScreenshotServicesService"))
        #expect(BuiltInApps.isOverlay("com.apple.PassbookUIService"))
        #expect(BuiltInApps.isOverlay("com.apple.BusinessActionSheet"))
        #expect(!BuiltInApps.isOverlay("com.apple.InCallService"))
        #expect(!BuiltInApps.isOverlay("com.apple.springboard"))
        #expect(!BuiltInApps.isOverlay("com.apple.mobilephone"))
        #expect(!BuiltInApps.isOverlay("com.apple.Passwords"))
    }

    /// A scan re-issued every token: the old scanned items lost theirs but kept their matches. Their apps are matched
    /// again, to the new tokens: counted to match, though the phone saw them long ago and an import ran after the scan.
    /// An app no scan lists needs a scan.
    @Test func matchesOfDroppedTokensDoNotCount() throws {
        let lastImport = Date(timeIntervalSince1970: 1_800_000_000)
        var app = data("com.app")
        app.firstSeen = lastImport.addingTimeInterval(-86_400)
        var dropped = scanned("old")
        dropped.tokenData = nil
        dropped.match = app.id
        var rescanned = scanned("new")
        rescanned.firstSeen = lastImport.addingTimeInterval(-60)
        var unlisted = data("com.unlisted")
        unlisted.firstSeen = app.firstSeen
        let items = [app, dropped, rescanned, unlisted]

        #expect(TokenMatching.matchedIDs(items).isEmpty)
        let unmatched = TokenMatching.unmatched(items, lastImport: lastImport)
        #expect(unmatched.toMatch.map(\.id) == [app.id])
        #expect(unmatched.toScan.map(\.id) == [unlisted.id])

        // Matched again: nothing left to match.
        var after = items
        _ = TokenMatching.apply([.init(scanned: rescanned.id, kind: .app, identifier: "com.app")], to: &after, kid: kid)
        let left = TokenMatching.unmatched(after, lastImport: lastImport.addingTimeInterval(120))
        #expect(left.toMatch.isEmpty)
        #expect(left.toScan.map(\.id) == [unlisted.id])
    }

    @Test func anotherItemMatchedToThePairedAppLosesItsMatch() {
        // `guess` was matched to com.game; Apple's list says com.game is `game`'s token.
        let game = scanned("game")
        var guess = scanned("guess")
        guess.match = TrackedItem.id(kid: kid, kind: .app, identifier: "com.game")
        var items = [game, guess, data("com.game")]

        let outcome = TokenMatching.apply([.init(scanned: game.id, kind: .app, identifier: "com.game")], to: &items, kid: kid)

        #expect(outcome.added == 1)
        #expect(outcome.cleared == 1)
        #expect(items[1].match == nil)
        #expect(Set(outcome.changed.map(\.id)) == [game.id, guess.id])
    }

    @Test func anItemThatLostItsTokenKeepsItsMatch() {
        // A later scan gave Camera a new token: the old item lost its token, and the new one pairs to Camera.
        let camera = data("com.apple.camera")
        var old = scanned("old")
        old.tokenData = nil
        old.match = camera.id
        let new = scanned("new")
        var items = [old, new, camera]

        let outcome = TokenMatching.apply([.init(scanned: new.id, kind: .app, identifier: "com.apple.camera")], to: &items, kid: kid)

        #expect(outcome.added == 1)
        #expect(outcome.cleared == 0)
        #expect(items[0].match == camera.id)
        #expect(outcome.changed.map(\.id) == [new.id])
    }

    @Test func onlyItemsWithATokenCountAsMatched() {
        // Camera's old token is gone and its new one isn't paired yet: Camera still needs matching.
        let camera = data("com.apple.camera")
        var old = scanned("old")
        old.tokenData = nil
        old.match = camera.id
        let items = [old, scanned("new"), camera]

        #expect(old.liveMatch == nil)
        #expect(TokenMatching.matchedIDs(items).isEmpty)
        #expect(TokenMatching.unmatched(items, lastImport: nil).toMatch.map(\.identifier) == ["com.apple.camera"])
    }

}
