import Foundation

/// Learns which app a scanned token is (PLAN.md §15.6). The app scan gives tokens without bundle IDs, Apple's data
/// bundle IDs without tokens. Each unmatched scanned app gets a DeviceActivity event at one minute of use counted from
/// its registration; when one fires, the app from Apple's data that has used about a minute since then is the one.
public enum TokenMatching {
    /// The event's threshold.
    public static let threshold: TimeInterval = 60
    /// Use since registration that counts as "about a minute": Apple's data and the event's count differ a little, and
    /// the wake that reads the data comes a moment after the crossing.
    public static let window: ClosedRange<TimeInterval> = 50...180

    /// How old Apple's data behind a baseline may be when the events are registered.
    public static let freshness: TimeInterval = 120

    /// Whether a baseline from data fetched at `dataAt` shows use as of `registeredAt`. Without a fetch that day
    /// (nil), it doesn't.
    public static func isFresh(dataAt: Date?, registeredAt: Date?) -> Bool {
        guard let dataAt, let registeredAt else { return false }
        return abs(registeredAt.timeIntervalSince(dataAt)) <= freshness
    }

    public enum Result: Equatable, Sendable {
        case matched(UUID)
        case none
        case ambiguous(Set<UUID>)
    }

    /// - Parameters:
    ///   - baseline: seconds per item from Apple's data when the event was registered (empty for a midnight start).
    ///   - previous: seconds per item at the fetch before this fire's. Of several apps near a minute, the one in use
    ///     just now is the one: another may have spent its minute long ago, its own event dropped or not yet matched.
    ///   - usage: seconds per item now.
    ///   - candidates: apps from Apple's data that no scanned item matches yet.
    public static func match(baseline: [UUID: Double], previous: [UUID: Double] = [:], usage: [UUID: Double],
                             candidates: Set<UUID>) -> Result {
        let near = Set(candidates.filter { window.contains((usage[$0] ?? 0) - (baseline[$0] ?? 0)) })
        // None grew: a wake fetched between the crossing and this fire, so growth says nothing.
        let growing = near.filter { (usage[$0] ?? 0) > (previous[$0] ?? 0) }
        let chosen = growing.isEmpty ? near : growing
        switch chosen.count {
        case 0: return .none
        case 1: return .matched(chosen.first!)
        default: return .ambiguous(chosen)
        }
    }
}
