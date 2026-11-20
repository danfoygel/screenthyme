import Foundation

/// Matches scanned tokens to Apple's bundle IDs and domains at once, through screenshots (PLAN.md §15.6).
///
/// Only the report extension sees a token beside its bundle ID, and its tokens are encrypted under another key than
/// the app scan's, so they can't be compared. But a report can be filtered by the scan's tokens, and iOS honors that.
/// So each scanned item gets a number (its place in `order`, from 1), and the app shows one report per bit of the
/// number, filtered to the items with that bit set, plus a parity report. Each report draws a QR code of short hashes
/// of the bundle IDs and domains it saw. An identifier's number is the sum of the bits of the reports it appears in.
/// A names report, filtered to every scanned item, spells the identifiers out, for those the phone hasn't seen in
/// Apple's data yet. Scanned categories are numbered apart, in reports of their own that spell the category names out.
/// The extension can't send anything, so the kid takes screenshots, and the app reads the codes back.
public enum TokenPairing {
    /// How far back the reports look: a week, in one weekly segment, which fetches far faster than 28 daily ones.
    /// Apps unused in it wait for another round.
    public static let days = 7
    static let header = "STPAIR2"

    /// Which scanned items a round of screenshots pairs. The app saves it in the App Group, for the report extension.
    public enum Mode: String, Codable, Sendable, CaseIterable {
        /// Scanned items with no match yet, and only apps, websites and categories nothing is matched to: after a
        /// first round, new apps' codes are small enough for one screenshot.
        case unmatched
        /// Every scanned item, checking every match again.
        case all
    }

    /// Scanned apps and websites with tokens (in `unmatched`, those with no match), in a fixed order; an item's number
    /// is its place + 1. The app and the report extension both derive it from the App Group's items.
    public static func order(_ items: [TrackedItem], mode: Mode) -> [TrackedItem] {
        items.filter { $0.isScanned && $0.kind != .category && $0.tokenData != nil && (mode == .all || $0.match == nil) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// Scanned categories with tokens (in `unmatched`, those with no match), numbered apart from apps and websites: a
    /// report filtered by a category shows every app in it, so categories can't share the apps' reports.
    public static func categoryOrder(_ items: [TrackedItem], mode: Mode) -> [TrackedItem] {
        items.filter { $0.isScanned && $0.kind == .category && $0.tokenData != nil && (mode == .all || $0.match == nil) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// Apps, websites and categories some scanned item is matched to.
    static func matched(_ items: [TrackedItem]) -> Set<Identifier> {
        let matches = Set(items.compactMap { $0.isScanned ? $0.match : nil })
        return Set(items.filter { matches.contains($0.id) }.map { Identifier(kind: $0.kind, identifier: $0.identifier) })
    }

    /// What a report draws of the identifiers it saw: in `unmatched`, not those a scanned item is matched to already
    /// (a second scanned token for a matched app would take its match away).
    public static func drawn(_ seen: Set<Identifier>, items: [TrackedItem], mode: Mode) -> Set<Identifier> {
        mode == .all ? seen : seen.subtracting(matched(items))
    }

    /// At most about how many identifiers a report filtered to `members` draws: one for each member used. In
    /// `unmatched`, no more than the apps, websites and categories this phone has seen that nothing is matched to, and
    /// a few spare for any it hasn't seen.
    public static func estimatedLines(members: [TrackedItem], items: [TrackedItem], mode: Mode) -> Int {
        guard mode == .unmatched else { return members.count }
        let matched = matched(items)
        let open = items.filter {
            !$0.isScanned && !matched.contains(Identifier(kind: $0.kind, identifier: $0.identifier))
        }
        let bound = [ItemKind.app, .domain, .category].reduce(0) { sum, kind in
            sum + min(members.count { $0.kind == kind }, open.count { $0.kind == kind })
        }
        return min(members.count, bound + 4)
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
        /// The same for scanned categories (`categoryOrder`), names spelled out: Apple has only about a dozen.
        case categoryParity
        case categoryBit(Int)

        /// Up to 511 scanned items.
        public static let maxBits = 9
        /// Up to 31 scanned categories.
        public static let maxCategoryBits = 5
        public static var allCases: [View] {
            [.names, .parity] + (0..<maxBits).map { .bit($0) } + [.categoryParity]
                + (0..<maxCategoryBits).map { .categoryBit($0) }
        }

        public var name: String {
            switch self {
            case .parity: "p"
            case let .bit(bit): "b\(bit)"
            case .names: "n"
            case .categoryParity: "cp"
            case let .categoryBit(bit): "c\(bit)"
            }
        }

        public init?(name: String) {
            if name == "p" {
                self = .parity
            } else if name == "n" {
                self = .names
            } else if name == "cp" {
                self = .categoryParity
            } else if name.hasPrefix("b"), let bit = Int(name.dropFirst()), (0..<Self.maxBits).contains(bit) {
                self = .bit(bit)
            } else if name.hasPrefix("c"), let bit = Int(name.dropFirst()), (0..<Self.maxCategoryBits).contains(bit) {
                self = .categoryBit(bit)
            } else {
                return nil
            }
        }

        /// A category report: filtered by `categoryOrder`, and it lists categories.
        public var isCategory: Bool {
            switch self {
            case .categoryParity, .categoryBit: true
            case .parity, .bit, .names: false
            }
        }

        public func contains(number: Int) -> Bool {
            switch self {
            case .parity, .categoryParity: number.nonzeroBitCount % 2 == 1
            case let .bit(bit), let .categoryBit(bit): number >> bit & 1 == 1
            case .names: true
            }
        }
    }

    /// The reports needed for `count` items (`names` is extra). None is empty: an empty filter would mean every app.
    public static func views(count: Int) -> [View] {
        guard count > 0 else { return [] }
        return [.parity] + (0..<(Int.bitWidth - count.leadingZeroBitCount)).map { .bit($0) }
    }

    /// The category reports needed for `count` scanned categories.
    public static func categoryViews(count: Int) -> [View] {
        guard count > 0 else { return [] }
        return [.categoryParity] + (0..<(Int.bitWidth - count.leadingZeroBitCount)).map { .categoryBit($0) }
    }

    /// The items a view's report is filtered to.
    public static func members(_ view: View, of order: [TrackedItem]) -> [TrackedItem] {
        order.enumerated().filter { view.contains(number: $0.offset + 1) }.map(\.element)
    }

    /// 6 hex digits: with the few dozen identifiers a report holds, a collision is rare, and it is detected.
    public static func hash(kind: ItemKind, identifier: String) -> String {
        String(format: "%06x", fnv1a("\(kind.rawValue):\(identifier)") & 0xFFFFFF)
    }

    /// A bundle ID, domain or category name, as the names and category reports spell it out.
    public struct Identifier: Hashable, Sendable {
        public var kind: ItemKind
        public var identifier: String

        public init(kind: ItemKind, identifier: String) {
            self.kind = kind
            self.identifier = identifier
        }

        var hash: String { TokenPairing.hash(kind: kind, identifier: identifier) }
        var line: String {
            let prefix = switch kind {
            case .app: "a"
            case .domain: "w"
            case .category: "c"
            }
            return "\(prefix) \(identifier)"
        }

        init?(line: String) {
            let fields = line.split(separator: " ", maxSplits: 1).map(String.init)
            let kinds: [String: ItemKind] = ["a": .app, "w": .domain, "c": .category]
            guard fields.count == 2, let kind = kinds[fields[0]] else { return nil }
            self.init(kind: kind, identifier: fields[1])
        }
    }

    /// A report's lines: hashes of what it saw, or for `names` and category reports, the identifiers spelled out.
    public static func lines(_ view: View, seen: some Sequence<Identifier>) -> [String] {
        view == .names || view.isCategory ? seen.map(\.line) : seen.map(\.hash)
    }

    /// One code holds up to 1150 bytes and its header (version 28, 129 modules): a bit report's hashes of up to 160
    /// identifiers, or the names of about 45. At `pixelsPerModule` with its quiet zone, that is as wide as a 2x phone's
    /// screen (343 points).
    public static let maxBytes = 1150

    /// How the reports draw their codes. In screenshots, as few codes as possible, each as full as it gets; for a
    /// parent's camera, one report fills the screen and cycles through smaller codes (version 19 at most, 93 modules),
    /// which a camera reads from arm's length in a moment. The kid app saves it in the App Group before showing reports.
    public enum Display: String, Codable, Sendable {
        case screenshots, camera

        public var maxBytes: Int {
            switch self {
            case .screenshots: TokenPairing.maxBytes
            case .camera: 600
            }
        }
    }

    /// The reports all of whose parts are among `codes`, by fingerprint.
    public static func complete(_ codes: some Sequence<Code>) -> [String: Set<View>] {
        var parts: [String: [View: (seen: Set<Int>, count: Int)]] = [:]
        for code in codes {
            parts[code.fingerprint, default: [:]][code.view, default: ([], code.parts)].seen.insert(code.part)
        }
        return parts.mapValues { views in Set(views.filter { $0.value.seen.count >= $0.value.count }.keys) }
    }

    /// Whole pixels a module. In a whole screenshot (1179 × 2556), Vision read every code at 5 px and missed about
    /// half at 4 px, and all of them at 3 (it scales the image down); it reads nothing at 1 px even in a small image.
    public static let pixelsPerModule = 5

    /// About how many modules wide, quiet zone included, the largest of a report's codes is for `lines` identifiers
    /// (`estimatedLines`), and how many codes there are. The app sizes the reports from it before they draw.
    public static func estimatedCodes(_ view: View, lines: Int) -> (count: Int, modules: Int) {
        let bytes = lines * (view == .names || view.isCategory ? 28 : 7)  // "a com.example.app\n"; a hash and a newline
        let count = max(1, (bytes + maxBytes - 1) / maxBytes)
        let size = QRCode.size(bytes: min(bytes, maxBytes) + 32) ?? 129  // the first is fullest
        return (count, size + 8)
    }

    /// How many columns to lay `count` square codes out in, to draw them as large as `size` allows.
    public static func columns(count: Int, width: Double, height: Double) -> Int {
        guard count > 1 else { return 1 }
        return (1...count).max { a, b in
            min(width / Double(a), height / Double((count + a - 1) / a))
                < min(width / Double(b), height / Double((count + b - 1) / b))
        } ?? 1
    }

    /// One report's codes: "STPAIR2 <fingerprint> <view> <part>/<parts>", then its lines.
    public static func encode(fingerprint: String, view: View, lines: [String], maxBytes: Int = maxBytes) -> [String] {
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
    ///   - order: `order(_:mode:)` of this phone's items now, in the mode the reports were drawn in.
    ///   - categories: `categoryOrder(_:mode:)` of this phone's items now, in the same mode.
    ///   - known: items from Apple's data, to look the hashes up in.
    public static func resolve(_ codes: some Sequence<Code>, order: [TrackedItem], categories: [TrackedItem] = [],
                               known: [TrackedItem]) -> Resolution {
        var resolution = Resolution()
        let fingerprints = (apps: fingerprint(order), categories: fingerprint(categories))
        var parts: [View: (seen: Set<Int>, count: Int)] = [:]
        var hashes: [View: Set<String>] = [:]
        for code in Set(codes) {
            guard code.fingerprint == (code.view.isCategory ? fingerprints.categories : fingerprints.apps) else {
                resolution.otherScan += 1
                continue
            }
            parts[code.view, default: ([], code.parts)].seen.insert(code.part)
            hashes[code.view, default: []].formUnion(code.lines)
        }
        let names = (hashes.removeValue(forKey: .names) ?? []).compactMap(Identifier.init(line:))
        let views = views(count: order.count)
        let categoryViews = categoryViews(count: categories.count)
        resolution.missing = (views + categoryViews)
            .filter { view in parts[view].map { $0.seen.count < $0.count } ?? true }.map(\.name)
        guard resolution.missing.isEmpty else { return resolution }

        var byHash: [String: Set<Identifier>] = [:]
        let identifiers = known.filter { !$0.isScanned && $0.kind != .category }
            .map { Identifier(kind: $0.kind, identifier: $0.identifier) } + names
        for identifier in identifiers { byHash[identifier.hash, default: []].insert(identifier) }
        pair(hashes, views: views, order: order, into: &resolution) { hash in
            guard let candidates = byHash[hash], candidates.count == 1 else { return nil }
            return candidates.first
        }
        pair(hashes, views: categoryViews, order: categories, into: &resolution) { line in
            Identifier(line: line).flatMap { $0.kind == .category ? $0 : nil }
        }
        resolution.pairs.sort { $0.identifier < $1.identifier }
        return resolution
    }

    /// Pairs the lines of `views`' codes with `order`'s items: a line's number is the sum of the bits of the reports it
    /// appears in. `identify` turns a line into what it names (nil: unknown).
    private static func pair(_ hashes: [View: Set<String>], views: [View], order: [TrackedItem],
                             into resolution: inout Resolution, identify: (String) -> Identifier?) {
        var byNumber: [Int: [Identifier]] = [:]
        for line in Set(views.flatMap { hashes[$0] ?? [] }) {
            guard let item = identify(line) else {
                resolution.unknown += 1
                continue
            }
            var number = 0
            var odd = false
            for view in views where hashes[view]?.contains(line) == true {
                switch view {
                case let .bit(bit), let .categoryBit(bit): number |= 1 << bit
                case .parity, .categoryParity: odd = true
                case .names: break
                }
            }
            guard number >= 1, number <= order.count, View.parity.contains(number: number) == odd,
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

    /// Sets each paired scanned item's match to the item for its bundle ID, domain or category name. That item's id comes from the
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

    /// Apps from Apple's data that no scanned item is matched to, by what would match them.
    public struct Unmatched: Sendable, Equatable {
        /// Another import may match them: they turned up since the last one (all of them, before the first), or the
        /// app scan has added apps since.
        public var toMatch: [TrackedItem] = []
        /// An import since they turned up didn't match them, and the scan has added nothing since: most likely installed
        /// after the last scan, so they need a new scan, then an import.
        public var toScan: [TrackedItem] = []

        public init() {}
    }

    /// Websites are left out: browsing turns up new domains all the time, mostly embedded ones the scan doesn't list. So
    /// are iOS's own processes, which no scan lists (`BuiltInApps.isSystemProcess`).
    /// - Parameter used: the apps to count, those used lately; nil counts them all. A deleted app stays unmatched.
    public static func unmatched(_ items: [TrackedItem], lastImport: Date?, used: Set<UUID>? = nil) -> Unmatched {
        let matched = Set(items.compactMap(\.match))
        // When the scan last added an app: a scanned item keeps the date it was first picked.
        let lastScan = items.filter { $0.isScanned && $0.tokenData != nil }.map(\.firstSeen).max()
        var result = Unmatched()
        for item in items where item.kind == .app && !item.isScanned && !matched.contains(item.id)
            && !BuiltInApps.isSystemProcess(item.identifier) && used.map({ $0.contains(item.id) }) ?? true {
            if let lastImport, item.firstSeen <= lastImport, lastScan.map({ $0 <= lastImport }) ?? true {
                result.toScan.append(item)
            } else {
                result.toMatch.append(item)
            }
        }
        return result
    }

    /// FNV-1a, 64-bit: stable across processes, unlike `Hasher`.
    static func fnv1a(_ string: String) -> UInt64 {
        string.utf8.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
    }
}
