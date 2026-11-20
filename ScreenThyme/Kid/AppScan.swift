import CryptoKit
import FamilyControls
import Foundation
import ManagedSettings
import ThymeCore

/// The app scan (PLAN.md §15.3): on the kid's phone, a parent selects All Apps & Categories once. Shields need
/// tokens, which Apple's usage data doesn't give (bundle IDs only) and the picker does (tokens only), so every app,
/// website and category becomes an item of its own (`TrackedItem.isScanned`). A second pick of ScreenThyme alone gives
/// its own token, which Downtime always lets through.
enum AppScan {
    struct Saved: Codable {
        var all = FamilyActivitySelection(includeEntireCategory: true)
        var screenThyme = FamilyActivitySelection()
    }

    static var url: URL { AppGroup.container.appending(path: "scan.json") }

    static func load() -> Saved {
        AppGroup.load(Saved.self, from: url) ?? Saved()
    }

    /// Saves the picks as items (new or changed ones go to the outbox) and enforces with them. Items the last scan
    /// picked and this one doesn't lose their token, so shields and parents' pickers drop them; tokens picked in Ask for
    /// more time stay (the scan's picker left Safari out, and a scan dropped the one the kid picked). A pick can re-issue
    /// every token (one did on a kid's phone): the old items keep their matches, which no longer count
    /// (`TokenPairing.matchedIDs`) but say those apps need a match round, to their new tokens (`TokenPairing.unmatched`), and policies naming them
    /// follow the app there (`Policy.followingNewTokens`).
    static func save(_ saved: Saved, kid: Kid, now: Date = Date()) {
        let before = Set(items(load().all, kid: kid, now: now).map(\.id))
        AppGroup.save(saved, to: url)
        let picked = items(saved.all, kid: kid, now: now)
        AppGroup.save(saved.screenThyme.applicationTokens.compactMap(TokenCoding.encode), to: AppGroup.exemptTokensURL)
        // An empty pick is a cancel: keep the last scan rather than unshield everything.
        guard !picked.isEmpty else {
            Task { await Enforcer.offMain { Enforcer.reconcile(now: now) } }
            return
        }
        // The sampler's lock: it rewrites items.json too.
        AppGroup.withLock("sampler") {
            var known = Dictionary(AppGroup.loadItems().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var changed: [TrackedItem] = []
            for pick in picked where known[pick.id]?.tokenData != pick.tokenData {
                var item = known[pick.id] ?? pick  // one a scan dropped keeps its match
                item.tokenData = pick.tokenData
                known[item.id] = item
                changed.append(item)
            }
            let dropped = before.subtracting(picked.map(\.id))
            var unmatched = 0  // matches of dropped tokens
            for (id, item) in known where dropped.contains(id) && item.tokenData != nil {
                if item.match != nil { unmatched += 1 }
                known[id]?.tokenData = nil
                changed.append(known[id]!)
            }
            AppGroup.saveItems(Array(known.values))
            try? AppGroup.newItems.append(contentsOf: changed)
            try? AppGroup.journal.append(.note("app scan: \(picked.count) picked, \(changed.count) changed"
                + (unmatched > 0 ? ", \(unmatched) matches to redo" : "")))
        }
        Task {
            await Enforcer.offMain { Enforcer.reconcile(now: now) }
        }
    }

    /// A pick's items: categories, apps, then websites.
    private static func items(_ selection: FamilyActivitySelection, kid: Kid, now: Date) -> [TrackedItem] {
        func items(_ kind: ItemKind, _ data: [Data]) -> [TrackedItem] {
            data.map { item(kind, tokenData: $0, kid: kid, now: now) }
        }
        return items(.category, selection.categoryTokens.compactMap(TokenCoding.encode))
            + items(.app, selection.applicationTokens.compactMap(TokenCoding.encode))
            + items(.domain, selection.webDomainTokens.compactMap(TokenCoding.encode))
    }

    private static func item(_ kind: ItemKind, tokenData: Data, kid: Kid, now: Date) -> TrackedItem {
        let hash = SHA256.hash(data: tokenData).prefix(8).map { String(format: "%02x", $0) }.joined()
        return TrackedItem(kidID: kid.id, kind: kind, identifier: TrackedItem.scannedPrefix + hash, tokenData: tokenData,
                           firstSeen: now)
    }

    /// The scanned item for an app picked in Apple's picker; one the scan doesn't list becomes an item now. An item a
    /// scan took this token from gets it back, with its match.
    static func item(for token: ApplicationToken, kid: Kid, now: Date = Date()) -> TrackedItem? {
        if let known = AppGroup.loadItems().first(where: { $0.kind == .app && TokenCoding.application($0.tokenData) == token }) {
            return known
        }
        guard let data = TokenCoding.encode(token) else { return nil }
        var result = item(.app, tokenData: data, kid: kid, now: now)
        AppGroup.withLock("sampler") {
            var items = AppGroup.loadItems()
            if let index = items.firstIndex(where: { $0.id == result.id }) {
                items[index].tokenData = data
                result = items[index]
            } else {
                items.append(result)
            }
            AppGroup.saveItems(items)
            try? AppGroup.newItems.append(contentsOf: [result])
        }
        return result
    }
}
