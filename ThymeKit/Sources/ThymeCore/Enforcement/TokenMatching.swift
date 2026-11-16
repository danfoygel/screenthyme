import Foundation

/// Learns which app a scanned token is (PLAN.md §15.5). The app scan gives tokens without bundle IDs, Apple's data
/// bundle IDs without tokens. Each unmatched scanned app gets a DeviceActivity event at one minute of use counted from
/// its registration; when one fires, the app from Apple's data that has used about a minute since then is the one.
public enum TokenMatching {
    /// The event's threshold.
    public static let threshold: TimeInterval = 60
    /// Use since registration that counts as "about a minute": Apple's data and the event's count differ a little, and
    /// the wake that reads the data comes a moment after the crossing.
    public static let window: ClosedRange<TimeInterval> = 50...180

    public enum Result: Equatable, Sendable {
        case matched(UUID)
        case none
        case ambiguous(Set<UUID>)
    }

    /// - Parameters:
    ///   - baseline: seconds per item from Apple's data when the event was registered (empty for a midnight start).
    ///   - usage: seconds per item now.
    ///   - candidates: apps from Apple's data that no scanned item matches yet.
    public static func match(baseline: [UUID: Double], usage: [UUID: Double], candidates: Set<UUID>) -> Result {
        let near = Set(candidates.filter { window.contains((usage[$0] ?? 0) - (baseline[$0] ?? 0)) })
        switch near.count {
        case 0: return .none
        case 1: return .matched(near.first!)
        default: return .ambiguous(near)
        }
    }
}
