import Foundation

/// Matches scanned tokens to Apple's bundle IDs, domains and category names. Apple's lists (`FamilyInventory`) give
/// each installed app, website and category its token and identifier at once; a scanned item learns its match here.
public enum TokenMatching {
    /// How far back "used lately" looks, for the apps parents see unmatched.
    public static let days = 7

    /// The items from Apple's data that a scanned item with a token is matched to. A scanned item a later scan dropped
    /// can't shield its app, so its match doesn't count: a scan can re-issue every token (it did on a kid's phone, all
    /// at once), and those apps must be matched again, to the new tokens.
    public static func matchedIDs(_ items: [TrackedItem]) -> Set<UUID> {
        Set(items.compactMap(\.liveMatch))
    }

    /// A scanned item and the bundle ID, domain or category name its token is.
    public struct Pair: Hashable, Sendable {
        public var scanned: UUID
        public var kind: ItemKind
        public var identifier: String

        public init(scanned: UUID, kind: ItemKind, identifier: String) {
            self.scanned = scanned
            self.kind = kind
            self.identifier = identifier
        }
    }

    public struct Outcome: Equatable, Sendable {
        /// Scanned items matched for the first time.
        public var added = 0
        /// Scanned items whose earlier match was different: the token is right.
        public var corrected = 0
        public var unchanged = 0
        /// Pairs whose scanned item isn't on this phone.
        public var unknown = 0
        /// Other scanned items that had been matched to one of these apps or websites: wrong, so unmatched.
        public var cleared = 0
        /// Apps and websites matched before this phone saw them in Apple's data: installed, but unused since tracking
        /// began. Created bare, so parents can name the match; they never count as new apps.
        public var created = 0
        /// The items whose match changed, and those created, to save and upload.
        public var changed: [TrackedItem] = []

        public init() {}
    }

    /// Sets each paired scanned item's match to the item for its bundle ID, domain or category name. That item's id comes from the
    /// kid and the identifier; one this phone hasn't seen yet is created. Another scanned item matched to the same app
    /// or website loses its match; one without a token keeps it, to say what it was.
    public static func apply(_ pairs: some Sequence<Pair>, to items: inout [TrackedItem], kid: UUID, now: Date = Date())
        -> Outcome {
        var outcome = Outcome()
        let indices = Dictionary(items.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        var changed: Set<Int> = []
        var paired: [UUID: Int] = [:]
        for pair in Set(pairs) {
            guard let index = indices[pair.scanned], items[index].isScanned, items[index].kidID == kid,
                  items[index].kind == pair.kind else {
                outcome.unknown += 1
                continue
            }
            let match = TrackedItem.id(kid: kid, kind: pair.kind, identifier: pair.identifier)
            switch items[index].match {
            case match: outcome.unchanged += 1
            case nil: outcome.added += 1
            default: outcome.corrected += 1
            }
            paired[match] = index
            if indices[match] == nil, !items.contains(where: { $0.id == match }) {
                items.append(TrackedItem(kidID: kid, kind: pair.kind, identifier: pair.identifier, firstSeen: now))
                changed.insert(items.count - 1)
                outcome.created += 1
            }
            guard items[index].match != match else { continue }
            items[index].match = match
            changed.insert(index)
        }
        for (index, item) in items.enumerated() where item.isScanned && item.kidID == kid {
            guard let match = item.liveMatch, let owner = paired[match], owner != index else { continue }
            items[index].match = nil
            changed.insert(index)
            outcome.cleared += 1
        }
        outcome.changed = changed.sorted().map { items[$0] }
        return outcome
    }

    /// Apps from Apple's data that no scanned item with a token is matched to, by what would match them.
    public struct Unmatched: Sendable, Equatable {
        /// The next import may match them: they turned up since the last one (all of them, before the first), the
        /// app scan has added apps since, or a scan re-issued their token (a scanned item without a token is still
        /// matched to them).
        public var toMatch: [TrackedItem] = []
        /// An import since they turned up didn't match them, and the scan has added nothing since: the scan doesn't
        /// list them. Apple's lists (`FamilyInventory`) list every installed app, so they aren't installed: Apple
        /// files a website's time under its App Store app too (`WebMirror` catches most). Limits count them only
        /// through their category or all apps.
        public var toScan: [TrackedItem] = []

        public init() {}
    }

    /// Websites are left out: browsing turns up new domains all the time, mostly embedded ones the scan doesn't list. So
    /// are iOS's own processes and Home Screen web apps, which no scan lists (`BuiltInApps.isSystemProcess`,
    /// `BuiltInApps.webApp`), and apps nothing can block (`BuiltInApps.unblockable`).
    /// - Parameter used: the apps to count, those used lately; nil counts them all. A deleted app stays unmatched.
    public static func unmatched(_ items: [TrackedItem], lastImport: Date?, used: Set<UUID>? = nil) -> Unmatched {
        let matched = matchedIDs(items)
        let reissued = Set(items.compactMap { $0.isScanned && $0.tokenData == nil ? $0.match : nil })
        // When the scan last added an app: a scanned item keeps the date it was first picked.
        let lastScan = items.filter { $0.isScanned && $0.tokenData != nil }.map(\.firstSeen).max()
        var result = Unmatched()
        for item in items where item.kind == .app && !item.isScanned && !matched.contains(item.id)
            && !BuiltInApps.isSystemProcess(item.identifier) && !BuiltInApps.unblockable.contains(item.identifier)
            && item.identifier != BuiltInApps.webApp
            && used.map({ $0.contains(item.id) }) ?? true {
            if let lastImport, item.firstSeen <= lastImport, lastScan.map({ $0 <= lastImport }) ?? true,
               !reissued.contains(item.id) {
                result.toScan.append(item)
            } else {
                result.toMatch.append(item)
            }
        }
        return result
    }
}
