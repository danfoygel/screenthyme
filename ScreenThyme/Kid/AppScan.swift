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

    /// Saves the picks as items (new or changed ones go to the outbox) and enforces with them. Items no longer picked
    /// lose their token, so shields and parents' pickers drop them; they keep their match, so policies naming them
    /// follow the app to its new token (`Policy.followingNewTokens`).
    static func save(_ saved: Saved, kid: Kid, now: Date = Date()) {
        AppGroup.save(saved, to: url)
        var picked: [TrackedItem] = []
        func add(_ kind: ItemKind, _ data: Data?) {
            data.map { picked.append(item(kind, tokenData: $0, kid: kid, now: now)) }
        }
        saved.all.categoryTokens.forEach { add(.category, TokenCoding.encode($0)) }
        saved.all.applicationTokens.forEach { add(.app, TokenCoding.encode($0)) }
        saved.all.webDomainTokens.forEach { add(.domain, TokenCoding.encode($0)) }
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
            for item in picked where known[item.id]?.tokenData != item.tokenData {
                var item = item
                item.firstSeen = known[item.id]?.firstSeen ?? now
                // A token picked again keeps its match and nickname.
                item.match = known[item.id]?.match
                item.nickname = known[item.id]?.nickname
                known[item.id] = item
                changed.append(item)
            }
            let ids = Set(picked.map(\.id))
            for (id, item) in known where item.isScanned && item.tokenData != nil && !ids.contains(id) {
                known[id]?.tokenData = nil
                changed.append(known[id]!)
            }
            AppGroup.saveItems(Array(known.values))
            try? AppGroup.newItems.append(contentsOf: changed)
            try? AppGroup.journal.append(.note("app scan: \(picked.count) picked, \(changed.count) changed"))
        }
        Task {
            await Enforcer.offMain { Enforcer.reconcile(now: now) }
        }
    }

    private static func item(_ kind: ItemKind, tokenData: Data, kid: Kid, now: Date) -> TrackedItem {
        let hash = SHA256.hash(data: tokenData).prefix(8).map { String(format: "%02x", $0) }.joined()
        return TrackedItem(kidID: kid.id, kind: kind, identifier: TrackedItem.scannedPrefix + hash, tokenData: tokenData,
                           firstSeen: now)
    }

    /// The scanned item for an app picked in Apple's picker; one installed since the scan becomes an item now.
    static func item(for token: ApplicationToken, kid: Kid, now: Date = Date()) -> TrackedItem? {
        if let known = AppGroup.loadItems().first(where: { $0.kind == .app && TokenCoding.application($0.tokenData) == token }) {
            return known
        }
        guard let data = TokenCoding.encode(token) else { return nil }
        let new = item(.app, tokenData: data, kid: kid, now: now)
        AppGroup.withLock("sampler") {
            AppGroup.saveItems(AppGroup.loadItems() + [new])
            try? AppGroup.newItems.append(contentsOf: [new])
        }
        return new
    }
}
