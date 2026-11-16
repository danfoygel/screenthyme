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
    /// lose their token, so shields and parents' pickers drop them.
    static func save(_ saved: Saved, kid: Kid, now: Date = Date()) {
        AppGroup.save(saved, to: url)
        var picked: [TrackedItem] = []
        func add(_ kind: ItemKind, _ data: Data?) {
            guard let data else { return }
            let hash = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
            picked.append(TrackedItem(kidID: kid.id, kind: kind, identifier: TrackedItem.scannedPrefix + hash,
                                      tokenData: data, firstSeen: now))
        }
        saved.all.categoryTokens.forEach { add(.category, TokenCoding.encode($0)) }
        saved.all.applicationTokens.forEach { add(.app, TokenCoding.encode($0)) }
        saved.all.webDomainTokens.forEach { add(.domain, TokenCoding.encode($0)) }
        AppGroup.save(saved.screenThyme.applicationTokens.compactMap(TokenCoding.encode), to: AppGroup.exemptTokensURL)
        // An empty pick is a cancel: keep the last scan rather than unshield everything.
        guard !picked.isEmpty else {
            Enforcer.reconcile(now: now)
            return
        }
        // The sampler's lock: it rewrites items.json too.
        AppGroup.withLock("sampler") {
            var known = Dictionary(AppGroup.loadItems().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var changed: [TrackedItem] = []
            for item in picked where known[item.id]?.tokenData != item.tokenData {
                var item = item
                item.firstSeen = known[item.id]?.firstSeen ?? now
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
        Enforcer.reconcile(now: now)
    }
}
