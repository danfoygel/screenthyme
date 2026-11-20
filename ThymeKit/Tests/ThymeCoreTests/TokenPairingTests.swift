import Foundation
import Testing
@testable import ThymeCore

struct TokenPairingTests {
    let kid = UUID()

    func scanned(_ hash: String, _ kind: ItemKind = .app) -> TrackedItem {
        TrackedItem(kidID: kid, kind: kind, identifier: TrackedItem.scannedPrefix + hash, tokenData: Data([1]),
                    firstSeen: Date())
    }

    func data(_ identifier: String, _ kind: ItemKind = .app) -> TrackedItem {
        TrackedItem(kidID: kid, kind: kind, identifier: identifier, firstSeen: Date())
    }

    /// What the report extension would draw if `truth` maps scanned items to the identifiers their tokens are.
    func codes(order: [TrackedItem], truth: [UUID: TrackedItem], names: Bool = false,
               maxBytes: Int = TokenPairing.maxBytes, items: [TrackedItem] = [],
               mode: TokenPairing.Mode = .all) -> [TokenPairing.Code] {
        let fingerprint = TokenPairing.fingerprint(order)
        return (TokenPairing.views(count: order.count) + (names ? [.names] : [])).flatMap { view in
            let seen = Set(TokenPairing.members(view, of: order).compactMap { truth[$0.id] }
                .map { TokenPairing.Identifier(kind: $0.kind, identifier: $0.identifier) })
            let drawn = TokenPairing.drawn(seen, items: items, mode: mode)
            return TokenPairing.encode(fingerprint: fingerprint, view: view, lines: TokenPairing.lines(view, seen: drawn),
                                       maxBytes: maxBytes)
        }
        .compactMap(TokenPairing.decode)
    }

    /// What the category reports would draw if `truth` maps scanned categories to Apple's category names.
    func categoryCodes(_ order: [TrackedItem], truth: [UUID: String]) -> [TokenPairing.Code] {
        let fingerprint = TokenPairing.fingerprint(order)
        return TokenPairing.categoryViews(count: order.count).flatMap { view in
            let seen = TokenPairing.members(view, of: order).compactMap { truth[$0.id] }
                .map { TokenPairing.Identifier(kind: .category, identifier: $0) }
            return TokenPairing.encode(fingerprint: fingerprint, view: view, lines: TokenPairing.lines(view, seen: seen))
        }
        .compactMap(TokenPairing.decode)
    }

    @Test func viewsCoverEveryNumberAndAreNeverEmpty() {
        #expect(TokenPairing.views(count: 0).isEmpty)
        #expect(TokenPairing.views(count: 1).map(\.name) == ["p", "b0"])
        #expect(TokenPairing.views(count: 169).map(\.name) == ["p", "b0", "b1", "b2", "b3", "b4", "b5", "b6", "b7"])
        let order = (0..<169).map { scanned("h\($0)") }
        for view in TokenPairing.views(count: order.count) {
            #expect(!TokenPairing.members(view, of: order).isEmpty)
        }
    }

    @Test func usedItemsResolveToTheirScannedItems() {
        let apps = (0..<81).map { scanned("a\($0)") }
        let sites = (0..<88).map { scanned("w\($0)", .domain) }
        let order = TokenPairing.order(apps + sites + [scanned("cat", .category)], mode: .all)
        #expect(order.count == 169)
        // Every third app and every fifth site was used.
        var truth: [UUID: TrackedItem] = [:]
        for (index, app) in apps.enumerated() where index % 3 == 0 { truth[app.id] = data("com.example.app\(index)") }
        for (index, site) in sites.enumerated() where index % 5 == 0 { truth[site.id] = data("site\(index).example.com", .domain) }

        let resolution = TokenPairing.resolve(codes(order: order, truth: truth, maxBytes: 80), order: order,
                                              known: Array(truth.values) + [data("com.unused")])

        #expect(resolution.missing.isEmpty)
        #expect(resolution.conflicts == 0)
        #expect(resolution.unknown == 0)
        #expect(Set(resolution.pairs) == Set(truth.map { TokenPairing.Pair(scanned: $0.key, kind: $0.value.kind,
                                                                                 identifier: $0.value.identifier) }))
    }

    @Test func aMissingReportPairsNothing() {
        let order = TokenPairing.order((0..<10).map { scanned("a\($0)") }, mode: .all)
        let truth = [order[3].id: data("com.three")]
        let partial = codes(order: order, truth: truth).filter { $0.view != .bit(2) }
        let resolution = TokenPairing.resolve(partial, order: order, known: Array(truth.values))
        #expect(resolution.missing == ["b2"])
        #expect(resolution.pairs.isEmpty)
    }

    @Test func codesFromAnotherScanAreSetAside() {
        let order = TokenPairing.order((0..<4).map { scanned("a\($0)") }, mode: .all)
        let old = TokenPairing.order((0..<5).map { scanned("a\($0)") }, mode: .all)
        let truth = [order[0].id: data("com.zero")]
        let resolution = TokenPairing.resolve(codes(order: order, truth: truth) + codes(order: old, truth: truth),
                                              order: order, known: Array(truth.values))
        #expect(resolution.otherScan > 0)
        #expect(resolution.pairs.map(\.identifier) == ["com.zero"])
    }

    @Test func identifiersThePhoneHasNotSeenAreUnknown() {
        let order = TokenPairing.order((0..<4).map { scanned("a\($0)") }, mode: .all)
        let resolution = TokenPairing.resolve(codes(order: order, truth: [order[1].id: data("com.new")]), order: order,
                                              known: [])
        #expect(resolution.unknown == 1)
        #expect(resolution.pairs.isEmpty)
    }

    @Test func theNamesReportSpellsOutWhatThePhoneHasNotSeen() {
        let order = TokenPairing.order((0..<20).map { scanned("a\($0)") } + [scanned("w", .domain)], mode: .all)
        let site = order.first { $0.kind == .domain }!
        let apps = order.filter { $0.kind == .app }
        let truth = [apps[1].id: data("com.new"), apps[7].id: data("com.seen"), site.id: data("new.example.com", .domain)]

        let resolution = TokenPairing.resolve(codes(order: order, truth: truth, names: true, maxBytes: 40), order: order,
                                              known: [data("com.seen")])

        #expect(resolution.unknown == 0)
        #expect(Set(resolution.pairs) == [.init(scanned: apps[1].id, kind: .app, identifier: "com.new"),
                                          .init(scanned: apps[7].id, kind: .app, identifier: "com.seen"),
                                          .init(scanned: site.id, kind: .domain, identifier: "new.example.com")])
    }

    @Test func twoScannedTokensForOneAppFailTheCheck() {
        // Items 1 and 2 (bits 01 and 10) are both com.dup: its hash lands in b0 and b1 but not in parity (3 is even).
        let order = TokenPairing.order((0..<4).map { scanned("a\($0)") }, mode: .all)
        let dup = data("com.dup")
        let resolution = TokenPairing.resolve(codes(order: order, truth: [order[0].id: dup, order[1].id: dup]),
                                              order: order, known: [dup])
        #expect(resolution.conflicts == 1)
        #expect(resolution.pairs.isEmpty)
    }

    @Test func categoriesPairThroughTheirOwnReports() {
        let apps = (0..<5).map { scanned("a\($0)") }
        let categories = (0..<13).map { scanned("c\($0)", .category) }
        let items = apps + categories
        let order = TokenPairing.order(items, mode: .all)
        let categoryOrder = TokenPairing.categoryOrder(items, mode: .all)
        #expect(order.count == 5)
        #expect(TokenPairing.categoryViews(count: categoryOrder.count).map(\.name) == ["cp", "c0", "c1", "c2", "c3"])
        let appTruth = [order[2].id: data("com.two")]
        // Two categories unused in the reports' days don't show up.
        let names = ["Social", "Games", "Entertainment", "Creativity", "Education", "Health & Fitness",
                     "Information & Reading", "Productivity & Finance", "Shopping & Food", "Travel", "Utilities"]
        let categoryTruth = Dictionary(uniqueKeysWithValues: zip(categoryOrder.map(\.id), names))

        let resolution = TokenPairing.resolve(codes(order: order, truth: appTruth)
                                                  + categoryCodes(categoryOrder, truth: categoryTruth),
                                              order: order, categories: categoryOrder, known: Array(appTruth.values))

        #expect(resolution.missing.isEmpty)
        #expect(resolution.conflicts == 0)
        #expect(resolution.unknown == 0)
        #expect(Set(resolution.pairs) == Set(categoryTruth.map { .init(scanned: $0.key, kind: .category, identifier: $0.value) })
            .union([.init(scanned: order[2].id, kind: .app, identifier: "com.two")]))
    }

    @Test func aMissingCategoryReportPairsNothing() {
        let categories = TokenPairing.categoryOrder((0..<6).map { scanned("c\($0)", .category) }, mode: .all)
        let partial = categoryCodes(categories, truth: [categories[0].id: "Social"]).filter { $0.view != .categoryBit(1) }
        let resolution = TokenPairing.resolve(partial, order: [], categories: categories, known: [])
        #expect(resolution.missing == ["c1"])
        #expect(resolution.pairs.isEmpty)
    }

    /// If iOS ignored a category filter, every report would list every category: no number fits.
    @Test func categoryReportsThatIgnoreTheirFilterPairNothing() {
        let categories = TokenPairing.categoryOrder((0..<6).map { scanned("c\($0)", .category) }, mode: .all)
        let fingerprint = TokenPairing.fingerprint(categories)
        let everything = ["Social", "Games"].map { TokenPairing.Identifier(kind: .category, identifier: $0) }
        let codes = TokenPairing.categoryViews(count: categories.count).flatMap {
            TokenPairing.encode(fingerprint: fingerprint, view: $0, lines: TokenPairing.lines($0, seen: everything))
        }
        let resolution = TokenPairing.resolve(codes.compactMap(TokenPairing.decode), order: [], categories: categories,
                                              known: [])
        #expect(resolution.pairs.isEmpty)
        #expect(resolution.conflicts == 2)
    }

    @Test func aCategoryPairMatchesApplesCategoryItem() {
        let category = scanned("c", .category)
        var items = [category]
        let outcome = TokenPairing.apply([.init(scanned: category.id, kind: .category, identifier: "Games")], to: &items,
                                         kid: kid)
        #expect(outcome.created == 1)
        // The id the sampler gives Apple's category, so its apps (`TrackedItem.category`) are found through the match.
        #expect(items[0].match == TrackedItem.id(kid: kid, kind: .category, identifier: "Games"))
        #expect(items.last?.displayName == "Games")
    }

    @Test func otherCodesAreIgnored() {
        #expect(TokenPairing.decode("https://example.com") == nil)
        #expect(TokenPairing.decode("STPAIR2 1234abcd b12 1/1\nabcdef") == nil)
        #expect(TokenPairing.decode("STPAIR2 1234abcd b3 2/1\nabcdef") == nil)
        #expect(TokenPairing.decode("STPAIR2 1234abcd p 1/1\nabcdef")?.lines == ["abcdef"])
        #expect(TokenPairing.decode("STPAIR2 1234abcd n 1/1\na com.x")?.view == .names)
        #expect(TokenPairing.decode("STPAIR2 1234abcd cp 1/1\nc Social")?.view == .categoryParity)
        #expect(TokenPairing.decode("STPAIR2 1234abcd c4 1/1\nc Social")?.view == .categoryBit(4))
        #expect(TokenPairing.decode("STPAIR2 1234abcd c5 1/1\nc Social") == nil)
    }

    @Test func applyMatchesCorrectsAndSkipsUnknown() {
        let new = scanned("new")
        var wrong = scanned("wrong")
        wrong.match = TrackedItem.id(kid: kid, kind: .app, identifier: "com.other")
        var right = scanned("right")
        right.match = TrackedItem.id(kid: kid, kind: .app, identifier: "com.right")
        var items = [new, wrong, right, data("com.new"), data("com.wrong"), data("com.right")]

        let outcome = TokenPairing.apply([.init(scanned: new.id, kind: .app, identifier: "com.new"),
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

        let outcome = TokenPairing.apply([.init(scanned: app.id, kind: .app, identifier: "com.seen"),
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
        var scannedApp = scanned("s")
        scannedApp.firstSeen = lastImport.addingTimeInterval(-120)
        scannedApp.match = newMatched.id
        let items = [old, new, newMatched, site, screenshot, scannedApp]

        let unmatched = TokenPairing.unmatched(items, lastImport: lastImport)
        #expect(unmatched.toMatch.map(\.identifier) == ["com.new"])
        // The last import saw it and didn't match it: the scan hasn't added it.
        #expect(unmatched.toScan.map(\.identifier) == ["com.old"])
        #expect(TokenPairing.unmatched(items, lastImport: nil).toMatch.map(\.identifier) == ["com.old", "com.new"])
        #expect(TokenPairing.unmatched(items, lastImport: nil).toScan.isEmpty)
        // Only the apps used lately.
        #expect(TokenPairing.unmatched(items, lastImport: lastImport, used: [new.id]).toScan.isEmpty)

        // A scan since the last import adds a token: the next import may match every app.
        var rescanned = scanned("r")
        rescanned.firstSeen = lastImport.addingTimeInterval(120)
        let afterScan = TokenPairing.unmatched(items + [rescanned], lastImport: lastImport)
        #expect(afterScan.toMatch.map(\.identifier) == ["com.old", "com.new"])
        #expect(afterScan.toScan.isEmpty)
    }

    @Test func systemProcessesAreTold() {
        #expect(BuiltInApps.isSystemProcess("com.apple.ScreenshotServicesService"))
        #expect(BuiltInApps.isSystemProcess("com.apple.InCallService"))
        #expect(BuiltInApps.isSystemProcess("com.apple.CoreAuthUI"))
        #expect(BuiltInApps.isSystemProcess("com.apple.springboard"))
        #expect(!BuiltInApps.isSystemProcess("com.apple.mobilesafari"))
        #expect(!BuiltInApps.isSystemProcess("com.apple.Pages"))
        #expect(!BuiltInApps.isSystemProcess("com.uo.StoreLocator"))
        #expect(!BuiltInApps.isSystemProcess("com.example.PushService"))
    }

    /// A scan re-issued every token: the old scanned items lost theirs but kept their matches. Their apps are matched
    /// again, to the new tokens: drawn in `unmatched` mode and counted to match, though the phone saw them long ago.
    @Test func matchesOfDroppedTokensDoNotCount() throws {
        let lastImport = Date(timeIntervalSince1970: 1_800_000_000)
        var app = data("com.app")
        app.firstSeen = lastImport.addingTimeInterval(-86_400)
        var dropped = scanned("old")
        dropped.tokenData = nil
        dropped.match = app.id
        var rescanned = scanned("new")
        rescanned.firstSeen = lastImport.addingTimeInterval(60)
        let items = [app, dropped, rescanned]

        #expect(TokenPairing.matchedIDs(items).isEmpty)
        #expect(TokenPairing.order(items, mode: .unmatched).map(\.id) == [rescanned.id])
        let seen: Set = [TokenPairing.Identifier(kind: .app, identifier: "com.app")]
        #expect(TokenPairing.drawn(seen, items: items, mode: .unmatched) == seen)
        let unmatched = TokenPairing.unmatched(items, lastImport: lastImport)
        #expect(unmatched.toMatch.map(\.id) == [app.id])
        #expect(unmatched.toScan.isEmpty)

        let order = TokenPairing.order(items, mode: .unmatched)
        let drawn = codes(order: order, truth: [rescanned.id: app], items: items, mode: .unmatched)
        let resolution = TokenPairing.resolve(drawn, order: order, known: items)
        #expect(resolution.pairs == [.init(scanned: rescanned.id, kind: .app, identifier: "com.app")])

        // Matched again: nothing left to match.
        var after = items
        _ = TokenPairing.apply(resolution.pairs, to: &after, kid: kid)
        #expect(TokenPairing.unmatched(after, lastImport: lastImport.addingTimeInterval(120)) == .init())
    }

    @Test func anotherItemMatchedToThePairedAppLosesItsMatch() {
        // Watching use matched `guess` to com.game; the reports show com.game is `game`'s token.
        let game = scanned("game")
        var guess = scanned("guess")
        guess.match = TrackedItem.id(kid: kid, kind: .app, identifier: "com.game")
        var items = [game, guess, data("com.game")]

        let outcome = TokenPairing.apply([.init(scanned: game.id, kind: .app, identifier: "com.game")], to: &items, kid: kid)

        #expect(outcome.added == 1)
        #expect(outcome.cleared == 1)
        #expect(items[1].match == nil)
        #expect(Set(outcome.changed.map(\.id)) == [game.id, guess.id])
    }

    /// After a first round matched most apps, a new app's codes hold only its own hash: all of them fit one screen.
    @Test func unmatchedModePairsNewAppsWithSmallCodes() throws {
        var scans = (0..<200).map { scanned("a\($0)") }
        var truth: [UUID: TrackedItem] = [:]
        var seen: [TrackedItem] = []
        for index in 0..<150 {
            let app = data("com.example.app\(index)")
            scans[index].match = app.id
            truth[scans[index].id] = app
            seen.append(app)
        }
        let new = data("com.new")
        truth[scans[180].id] = new
        // A second scanned token for a matched app stays out of it: that app keeps its match.
        truth[scans[190].id] = truth[scans[3].id]
        let items = scans + seen + [new]

        let order = TokenPairing.order(items, mode: .unmatched)
        #expect(order.count == 50)
        let drawn = codes(order: order, truth: truth, names: true, items: items, mode: .unmatched)
        #expect(drawn.count == TokenPairing.views(count: order.count).count + 1)
        #expect(drawn.allSatisfy { $0.lines.count <= 1 })

        let resolution = TokenPairing.resolve(drawn, order: order, known: items)
        #expect(resolution.pairs == [.init(scanned: scans[180].id, kind: .app, identifier: "com.new")])
        #expect(resolution.conflicts == 0)
        #expect(resolution.unknown == 0)

        for view in TokenPairing.views(count: order.count) + [.names] {
            let members = view == .names ? order : TokenPairing.members(view, of: order)
            let lines = TokenPairing.estimatedLines(members: members, items: items, mode: .unmatched)
            #expect(lines == 5, "\(view.name)")  // the one app nothing is matched to, and spare
            let estimate = TokenPairing.estimatedCodes(view, lines: lines)
            #expect(estimate.count == 1)
            // 5 px a module: a bit report's code is 113 points wide on a 2x phone, three to a row.
            #expect(estimate.modules <= (view == .names ? 61 : 45), "\(view.name)")
        }
        #expect(TokenPairing.estimatedLines(members: order, items: items, mode: .all) == 50)
        #expect(TokenPairing.order(items, mode: .all).count == 200)
    }

    @Test func unmatchedModeLeavesMatchedCategoriesOut() {
        let apple = data("Social", .category)
        var social = scanned("c0", .category)
        social.match = apple.id
        let games = scanned("c1", .category)
        let items = [social, games, apple, data("Games", .category)]

        #expect(TokenPairing.categoryOrder(items, mode: .unmatched).map(\.id) == [games.id])
        #expect(TokenPairing.categoryOrder(items, mode: .all).count == 2)
        let seen: Set = [TokenPairing.Identifier(kind: .category, identifier: "Social"),
                         .init(kind: .category, identifier: "Games")]
        #expect(TokenPairing.drawn(seen, items: items, mode: .unmatched) == [.init(kind: .category, identifier: "Games")])
    }

    /// 207 identifiers: each bit report's hashes fit one code, and no code is wider than a 2x phone's screen.
    @Test func estimatesCoverWhatIsDrawn() throws {
        let order = (0..<207).map { scanned("h\($0)") }
        let truth = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1.id, data("com.example.app\($0)")) })
        let drawn = Dictionary(grouping: codes(order: order, truth: truth, names: true), by: \.view)
        for (view, codes) in drawn {
            let estimate = TokenPairing.estimatedCodes(view, lines: TokenPairing.members(view, of: order).count)
            #expect(estimate.count >= codes.count, "\(view.name)")
            let text = TokenPairing.encode(fingerprint: TokenPairing.fingerprint(order), view: view,
                                           lines: codes.flatMap(\.lines))
            let largest = try #require(text.compactMap { QRCode(Array($0.utf8)) }.map(\.size).max())
            #expect(largest <= 129, "\(view.name)")
            #expect(estimate.modules >= largest + 8, "\(view.name)")
            #expect(estimate.modules <= largest + 8 + 12, "\(view.name)")
        }
        #expect(drawn[.bit(0)]?.count == 1)
        #expect((drawn[.names]?.count ?? 0) > 1)
    }

    /// A full code, header and all, is version 28 at most: 137 modules with the quiet zone, 5 px each at 2x.
    @Test func aFullCodeFitsA2xScreen() throws {
        let lines = (0..<TokenPairing.maxBytes / 7).map { String(format: "%06x", $0) }
        let text = try #require(TokenPairing.encode(fingerprint: "ffffffff", view: .bit(8), lines: lines).first)
        let code = try #require(QRCode(Array(text.utf8)))
        #expect(code.version <= 28)
        #expect(Double((code.size + 8) * TokenPairing.pixelsPerModule) / 2 <= 343)
    }

    /// A camera's codes are small enough to read from arm's length, header and all.
    @Test func aCameraCodeIsSmall() throws {
        let lines = (0..<TokenPairing.Display.camera.maxBytes / 7).map { String(format: "%06x", $0) }
        let texts = TokenPairing.encode(fingerprint: "ffffffff", view: .bit(8), lines: lines,
                                        maxBytes: TokenPairing.Display.camera.maxBytes)
        #expect(texts.count == 1)
        let code = try #require(QRCode(Array(texts[0].utf8)))
        #expect(code.version <= 19)
    }

    /// A report is complete once every one of its parts was read, whatever the order; other scans' codes stay apart.
    @Test func completeReportsHaveEveryPart() {
        let apps = (0..<60).map { scanned("a\($0)") }
        let order = TokenPairing.order(apps, mode: .all)
        var truth: [UUID: TrackedItem] = [:]
        for (index, app) in apps.enumerated() { truth[app.id] = data("com.example.app\(index)") }
        let all = codes(order: order, truth: truth, maxBytes: 80)
        let fingerprint = TokenPairing.fingerprint(order)
        let parity = all.filter { $0.view == .parity }
        #expect(parity.count > 1)

        let partial = all.filter { $0.view != .parity } + parity.dropFirst()
        #expect(TokenPairing.complete(partial)[fingerprint] == Set(TokenPairing.views(count: order.count)).subtracting([.parity]))
        #expect(TokenPairing.complete(all.reversed())[fingerprint] == Set(TokenPairing.views(count: order.count)))

        var other = parity[0]
        other.fingerprint = "00000000"
        other.parts = 1
        #expect(TokenPairing.complete([other] + parity.dropFirst()) == ["00000000": [.parity], fingerprint: []])
    }

    @Test func sizesWithoutDrawingMatchTheCodes() throws {
        for bytes in [0, 1, 13, 14, 60, 300, 1150, 2331] {
            let code = try #require(QRCode([UInt8](repeating: 0x61, count: bytes)))
            #expect(QRCode.size(bytes: bytes) == code.size, "\(bytes)")
        }
        #expect(QRCode.size(bytes: 3000) == nil)
    }

    @Test func columnsDrawCodesLargest() {
        #expect(TokenPairing.columns(count: 1, width: 100, height: 300) == 1)
        #expect(TokenPairing.columns(count: 2, width: 170, height: 170) == 1)
        #expect(TokenPairing.columns(count: 2, width: 360, height: 170) == 2)
        #expect(TokenPairing.columns(count: 3, width: 360, height: 360) == 2)
        #expect(TokenPairing.columns(count: 3, width: 360, height: 540) == 1)
    }
}
