import Foundation

/// A kid's day in one number, as parents see it: the phone's in-use minutes or Apple's apps, whichever is more, less
/// the use of Uncounted apps (`Policy.uncounted`), which still shows as theirs.
public struct DayTotal: Sendable, Hashable {
    /// Apple's apps as all-apps totals count them (`EnforcementPlanner.totalSeconds`): without websites (also Safari's),
    /// `mirrored` apps (Safari's on their website) or Uncounted ones.
    public var appMinutes: Int
    /// The total ladder's in-use minutes, less Uncounted use.
    public var inUseMinutes: Int
    /// What Uncounted apps and websites held.
    public var uncountedMinutes: Int

    /// The day's total.
    public var minutes: Int { max(inUseMinutes, appMinutes) }

    /// - Parameter policy: the kid's policy that day, resolved here.
    public init(_ timeline: DayTimeline, items: [UUID: TrackedItem], policy: Policy, mirrored: Set<UUID> = []) {
        let usage = timeline.items.mapValues(\.seconds)
        let resolved = policy.resolved(items: items)
        let items = CustomCategories(policy: resolved, items: items).categorizing(items)
        let uncounted = resolved.uncountedSeconds(items: items, usage: usage, mirrored: mirrored)
        let apps = EnforcementPlanner.totalSeconds(items: items, usage: usage, excluding: mirrored.union(resolved.uncounted))
        appMinutes = Int((apps / 60).rounded())
        uncountedMinutes = Int((uncounted / 60).rounded())
        inUseMinutes = max(0, timeline.totalMinutes - uncountedMinutes)
    }
}
