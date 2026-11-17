import Foundation

/// Matches scanned tokens to Apple's bundle IDs and domains at once, through screenshots (PLAN.md §15.6).
///
/// Only the report extension sees a token beside its bundle ID, and its tokens are encrypted under another key than
/// the app scan's, so they can't be compared. But a report can be filtered by the scan's tokens, and iOS honors that.
/// So each scanned item gets a number (its place in `order`, from 1), and the app shows one report per bit of the
/// number, filtered to the items with that bit set, plus a parity report. Each report draws a QR code of short hashes
/// of the bundle IDs and domains it saw. An identifier's number is the sum of the bits of the reports it appears in.
/// A names report, filtered to every scanned item, spells the identifiers out, for those the phone hasn't seen in
/// Apple's data yet.
/// The extension can't send anything, so the kid takes screenshots, and the app reads the codes back.
public enum TokenPairing {
    /// How far back the reports look.
    public static let days = 28
    static let header = "STPAIR2"

    /// Scanned apps and websites with tokens, in a fixed order; an item's number is its place + 1. The app and the
    /// report extension both derive it from the App Group's items.
    public static func order(_ items: [TrackedItem]) -> [TrackedItem] {
        items.filter { $0.isScanned && $0.kind != .category && $0.tokenData != nil }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// Names one `order`, so codes from another scan are told apart.
    public static func fingerprint(_ order: [TrackedItem]) -> String {
        String(format: "%08x", UInt32(truncatingIfNeeded: fnv1a(order.map(\.id.uuidString).joined(separator: ","))))
    }

    public enum View: Hashable, Sendable, CaseIterable {
        case parity
        case bit(Int)
        /// Every scanned item; spells out the identifiers instead of hashing them. Optional.
        case names

        /// Up to 511 scanned items.
        public static let maxBits = 9
        public static var allCases: [View] { [.names, .parity] + (0..<maxBits).map { .bit($0) } }

        public var name: String {
            switch self {
            case .parity: "p"
            case let .bit(bit): "b\(bit)"
            case .names: "n"
            }
        }

        public init?(name: String) {
            if name == "p" {
                self = .parity
            } else if name == "n" {
                self = .names
            } else if name.hasPrefix("b"), let bit = Int(name.dropFirst()), (0..<Self.maxBits).contains(bit) {
                self = .bit(bit)
            } else {
                return nil
            }
        }

        public func contains(number: Int) -> Bool {
            switch self {
            case .parity: number.nonzeroBitCount % 2 == 1
            case let .bit(bit): number >> bit & 1 == 1
            case .names: true
            }
        }
    }

    /// The reports needed for `count` items (`names` is extra). None is empty: an empty filter would mean every app.
    public static func views(count: Int) -> [View] {
        guard count > 0 else { return [] }
        return [.parity] + (0..<(Int.bitWidth - count.leadingZeroBitCount)).map { .bit($0) }
    }

    /// The items a view's report is filtered to.
    public static func members(_ view: View, of order: [TrackedItem]) -> [TrackedItem] {
        order.enumerated().filter { view.contains(number: $0.offset + 1) }.map(\.element)
    }

    /// 6 hex digits: with the few dozen identifiers a report holds, a collision is rare, and it is detected.
    public static func hash(kind: ItemKind, identifier: String) -> String {
        String(format: "%06x", fnv1a("\(kind.rawValue):\(identifier)") & 0xFFFFFF)
    }

    /// A bundle ID or domain, as the names report spells it out.
    public struct Identifier: Hashable, Sendable {
        public var kind: ItemKind
        public var identifier: String

        public init(kind: ItemKind, identifier: String) {
            self.kind = kind
            self.identifier = identifier
        }

        var hash: String { TokenPairing.hash(kind: kind, identifier: identifier) }
        var line: String { "\(kind == .app ? "a" : "w") \(identifier)" }

        init?(line: String) {
            let fields = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard fields.count == 2, ["a", "w"].contains(fields[0]) else { return nil }
            self.init(kind: fields[0] == "a" ? .app : .domain, identifier: fields[1])
        }
    }

    /// A report's lines: hashes of what it saw, or for `names`, the identifiers spelled out.
    public static func lines(_ view: View, seen: some Sequence<Identifier>) -> [String] {
        view == .names ? seen.map(\.line) : seen.map(\.hash)
    }

    /// The names report needs about 1.6 KB for 60 identifiers: one large code, drawn wide.
    public static func maxBytes(_ view: View) -> Int { view == .names ? 2000 : 600 }

    /// One report's codes: "STPAIR2 <fingerprint> <view> <part>/<parts>", then its lines.
    public static func encode(fingerprint: String, view: View, lines: [String], maxBytes: Int? = nil) -> [String] {
        let maxBytes = maxBytes ?? self.maxBytes(view)
        var chunks: [[String]] = [[]]
        var size = 0
        for line in Set(lines).sorted() {
            if size + line.utf8.count + 1 > maxBytes, !chunks[chunks.count - 1].isEmpty {
                chunks.append([])
                size = 0
            }
            chunks[chunks.count - 1].append(line)
            size += line.utf8.count + 1
        }
        return chunks.enumerated().map { index, lines in
            (["\(header) \(fingerprint) \(view.name) \(index + 1)/\(chunks.count)"] + lines).joined(separator: "\n")
        }
    }

    public struct Code: Hashable, Sendable {
        public var fingerprint: String
        public var view: View
        public var part: Int
        public var parts: Int
        public var lines: [String]
    }

    /// One code's text, or nil if it isn't ours.
    public static func decode(_ text: String) -> Code? {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let first = lines.first else { return nil }
        let fields = first.split(separator: " ").map(String.init)
        guard fields.count == 4, fields[0] == header, let view = View(name: fields[2]) else { return nil }
        let part = fields[3].split(separator: "/").compactMap { Int($0) }
        guard part.count == 2, (1...part[1]).contains(part[0]) else { return nil }
        return Code(fingerprint: fields[1], view: view, part: part[0], parts: part[1], lines: Array(lines.dropFirst()))
    }

    /// A scanned item and the bundle ID or domain its token is.
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

    public struct Resolution: Equatable, Sendable {
        public var pairs: [Pair] = []
        /// Reports whose codes (or some of their parts) weren't among the screenshots: nothing can be paired.
        public var missing: [String] = []
        /// Codes drawn for another scan (the scan changed since the screenshots).
        public var otherScan = 0
        /// Identifiers this phone hasn't seen in Apple's data yet and the names report didn't spell out (or whose hash
        /// two identifiers share).
        public var unknown = 0
        /// Numbers that fail the parity check or don't fit the scan: two scanned items for one app, or a misread.
        public var conflicts = 0

        public init() {}
    }

    /// - Parameters:
    ///   - order: `order(_:)` of this phone's items now.
    ///   - known: items from Apple's data, to look the hashes up in.
    public static func resolve(_ codes: some Sequence<Code>, order: [TrackedItem], known: [TrackedItem]) -> Resolution {
        var resolution = Resolution()
        let fingerprint = fingerprint(order)
        var parts: [View: (seen: Set<Int>, count: Int)] = [:]
        var hashes: [View: Set<String>] = [:]
        for code in Set(codes) {
            guard code.fingerprint == fingerprint else {
                resolution.otherScan += 1
                continue
            }
            parts[code.view, default: ([], code.parts)].seen.insert(code.part)
            hashes[code.view, default: []].formUnion(code.lines)
        }
        let names = (hashes.removeValue(forKey: .names) ?? []).compactMap(Identifier.init(line:))
        let views = views(count: order.count)
        resolution.missing = views.filter { view in parts[view].map { $0.seen.count < $0.count } ?? true }.map(\.name)
        guard resolution.missing.isEmpty else { return resolution }

        var byHash: [String: Set<Identifier>] = [:]
        let identifiers = known.filter { !$0.isScanned && $0.kind != .category }
            .map { Identifier(kind: $0.kind, identifier: $0.identifier) } + names
        for identifier in identifiers { byHash[identifier.hash, default: []].insert(identifier) }
        var byNumber: [Int: [Identifier]] = [:]
        for hash in Set(hashes.values.flatMap { $0 }) {
            guard let candidates = byHash[hash], candidates.count == 1, let item = candidates.first else {
                resolution.unknown += 1
                continue
            }
            let number = views.reduce(0) { sum, view in
                guard case let .bit(bit) = view, hashes[view]?.contains(hash) == true else { return sum }
                return sum | 1 << bit
            }
            guard (1...order.count).contains(number), View.parity.contains(number: number) == hashes[.parity]?.contains(hash),
                  order[number - 1].kind == item.kind else {
                resolution.conflicts += 1
                continue
            }
            byNumber[number, default: []].append(item)
        }
        for (number, items) in byNumber {
            guard items.count == 1, let item = items.first else {
                resolution.conflicts += items.count
                continue
            }
            resolution.pairs.append(Pair(scanned: order[number - 1].id, kind: item.kind, identifier: item.identifier))
        }
        resolution.pairs.sort { $0.identifier < $1.identifier }
        return resolution
    }

    public struct Outcome: Equatable, Sendable {
        /// Scanned items matched for the first time.
        public var added = 0
        /// Scanned items whose match from watching use was different: the token is right.
        public var corrected = 0
        public var unchanged = 0
        /// Pairs whose scanned item isn't on this phone.
        public var unknown = 0
        /// Other scanned items that had been matched to one of these apps or websites by watching use: wrong, so
        /// unmatched, and watched again.
        public var cleared = 0
        /// Apps and websites matched before this phone saw them in Apple's data: used in the reports' days, but
        /// before tracking began. Created bare, so parents can name the match; they never count as new apps.
        public var created = 0
        /// The items whose match changed, and those created, to save and upload.
        public var changed: [TrackedItem] = []

        public init() {}
    }

    /// Sets each paired scanned item's match to the item for its bundle ID or domain. That item's id comes from the
    /// kid and the identifier; one this phone hasn't seen yet is created. Another scanned item matched to the same app
    /// or website loses its match.
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
            guard let match = item.match, let owner = paired[match], owner != index else { continue }
            items[index].match = nil
            changed.insert(index)
            outcome.cleared += 1
        }
        outcome.changed = changed.sorted().map { items[$0] }
        return outcome
    }

    /// Apps from Apple's data that no scanned item is matched to and that turned up after the last import (all of them,
    /// before the first): another import may match them. Websites are left out: browsing turns up new domains all the
    /// time, mostly embedded ones the scan doesn't list.
    public static func toMatch(_ items: [TrackedItem], lastImport: Date?) -> [TrackedItem] {
        let matched = Set(items.compactMap(\.match))
        return items.filter { item in
            item.kind == .app && !item.isScanned && !matched.contains(item.id)
                && lastImport.map { item.firstSeen > $0 } ?? true
        }
    }

    /// FNV-1a, 64-bit: stable across processes, unlike `Hasher`.
    static func fnv1a(_ string: String) -> UInt64 {
        string.utf8.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
    }
}
