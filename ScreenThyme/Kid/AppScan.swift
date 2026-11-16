import CryptoKit
import FamilyControls
import Foundation
import ManagedSettings
import ThymeCore

/// The app scan (PLAN.md §15.3): on the kid's phone, a parent picks all categories and the apps to manage one by one.
/// Shields need tokens, which Apple's usage data doesn't give (bundle IDs only) and the picker does (tokens only), so
/// the picks become items of their own (`TrackedItem.isScanned`).
enum AppScan {
    /// A store shields at most 50 apps, and an "all except" list names at most 50; leave room for Always Allowed.
    static let maxApps = 40

    struct Saved: Codable {
        var categories = FamilyActivitySelection()
        var apps = FamilyActivitySelection()
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
        for selection in [saved.categories, saved.apps] {
            selection.categoryTokens.forEach { add(.category, TokenCoding.encode($0)) }
            selection.applicationTokens.forEach { add(.app, TokenCoding.encode($0)) }
            selection.webDomainTokens.forEach { add(.domain, TokenCoding.encode($0)) }
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
