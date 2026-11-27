import CryptoKit
import Foundation

/// The app scan and token matching at once, with no picker (PLAN.md §15.3). Under data access,
/// Apple lists every installed app, visited website and category with both its name and its token. Its tokens are
/// byte for byte the picker's, so each becomes the scanned item a scan would make (the same id), matched to the item
/// for its bundle ID, domain or category name.
public enum FamilyInventory {
    /// One app, website or category as Apple lists it.
    public struct Entry: Hashable, Sendable {
        public var kind: ItemKind
        /// Bundle ID, domain or category name.
        public var identifier: String
        /// The JSON-encoded token, as the scan stores it.
        public var tokenData: Data

        public init(kind: ItemKind, identifier: String, tokenData: Data) {
            self.kind = kind
            self.identifier = identifier
            self.tokenData = tokenData
        }
    }

    public struct Outcome: Sendable {
        /// Scanned items made, or given their token back (a scan had dropped it).
        public var tokens = 0
        public var pairing = TokenMatching.Outcome()
        /// Every item made or changed, to save and upload.
        public var changed: [TrackedItem] = []

        public init() {}
    }

    /// Makes or updates each entry's scanned item and matches it. Never drops a token: the websites list covers only
    /// recent visits, and a token for a site that aged out of it still shields.
    public static func apply(_ entries: some Sequence<Entry>, to items: inout [TrackedItem], kid: UUID,
                             now: Date = Date()) -> Outcome {
        var outcome = Outcome()
        var indices = Dictionary(items.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        var changed: Set<UUID> = []
        var pairs: [TokenMatching.Pair] = []
        for entry in Set(entries) where !entry.identifier.isEmpty {
            let identifier = TrackedItem.scannedIdentifier(tokenData: entry.tokenData)
            let id = TrackedItem.id(kid: kid, kind: entry.kind, identifier: identifier)
            if let index = indices[id] {
                if items[index].tokenData != entry.tokenData {
                    items[index].tokenData = entry.tokenData
                    changed.insert(id)
                    outcome.tokens += 1
                }
            } else {
                items.append(TrackedItem(kidID: kid, kind: entry.kind, identifier: identifier,
                                         tokenData: entry.tokenData, firstSeen: now))
                indices[id] = items.count - 1
                changed.insert(id)
                outcome.tokens += 1
            }
            pairs.append(TokenMatching.Pair(scanned: id, kind: entry.kind, identifier: entry.identifier))
        }
        outcome.pairing = TokenMatching.apply(pairs, to: &items, kid: kid, now: now)
        changed.formUnion(outcome.pairing.changed.map(\.id))
        outcome.changed = items.filter { changed.contains($0.id) }
        return outcome
    }
}

extension TrackedItem {
    /// A scanned item's identifier: the prefix and a hash of its token, so a token picked or listed again finds its
    /// item.
    public static func scannedIdentifier(tokenData: Data) -> String {
        scannedPrefix + SHA256.hash(data: tokenData).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
