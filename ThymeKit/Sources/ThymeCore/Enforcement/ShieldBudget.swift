import Foundation

/// iOS shields at most 50 apps and 50 websites one by one (`shield.applications`, `shield.webDomains`), and the cap is
/// for all of an app's ManagedSettings stores together: past it, some go unshielded without an error (Nov 22: a 108-app
/// limit spread over stores of 50 let Netflix through, while Netflix alone was blocked). When more are due, the
/// Enforcer shields the ones used most recently today. Any other that's opened is used, so it moves up at the next wake
/// (about a minute of use). Categories aren't shielded one by one and don't count.
public enum ShieldBudget {
    public static let cap = 50

    /// An app's or website's use today, from Apple's hourly data.
    public struct Use: Sendable, Hashable {
        /// The start of the last hour it was used in.
        public var lastHour: Date
        public var seconds: Double

        public init(lastHour: Date, seconds: Double) {
            self.lastHour = lastHour
            self.seconds = seconds
        }
    }

    /// The lists (always blocked, Downtime for some apps, limits) within the cap: at most `cap` apps and `cap` websites
    /// in all, the ones used most recently today first (then the most used), each in the first list that holds it.
    /// Categories stay in every list. `use` is by Apple's items; a scanned item goes by its match's.
    /// - Returns: the lists to shield, and the apps and websites left out.
    public static func fit(_ lists: [Set<UUID>], items: [UUID: TrackedItem], use: [UUID: Use], cap: Int = cap)
        -> (lists: [Set<UUID>], left: Set<UUID>) {
        let oneByOne: (UUID) -> Bool = { id in items[id].map { $0.kind != .category } ?? false }
        var fitted = lists.map { $0.filter { !oneByOne($0) } }
        var first: [UUID: Int] = [:]
        for (index, list) in lists.enumerated() {
            for id in list where oneByOne(id) && first[id] == nil { first[id] = index }
        }
        let use: (UUID) -> Use? = { id in use[id] ?? items[id]?.liveMatch.flatMap { use[$0] } }
        var left = Set<UUID>()
        for kind in [ItemKind.app, .domain] {
            let ranked = first.keys.filter { items[$0]?.kind == kind }.sorted { a, b in
                let (useA, useB) = (use(a), use(b))
                if useA?.lastHour != useB?.lastHour { return (useA?.lastHour ?? .distantPast) > (useB?.lastHour ?? .distantPast) }
                if useA?.seconds != useB?.seconds { return (useA?.seconds ?? 0) > (useB?.seconds ?? 0) }
                if first[a] != first[b] { return first[a]! < first[b]! }
                return a.uuidString < b.uuidString
            }
            for (rank, id) in ranked.enumerated() {
                if rank < cap { fitted[first[id]!].insert(id) } else { left.insert(id) }
            }
        }
        return (fitted, left)
    }
}
