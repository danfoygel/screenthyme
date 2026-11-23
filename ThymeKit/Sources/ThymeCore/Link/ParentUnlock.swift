import Foundation

/// A parent's phone nearby unlocked a kid phone's parent controls (PLAN.md §17): the app scan, matching by
/// screenshot, choosing ScreenThyme, starting monitoring, one more minute's length and Debug. Only a parent's phone
/// starts it, over the nearby link, so a parent is with the phone. The kid's phone keeps it in memory, so it ends when
/// ScreenThyme leaves the foreground, and times it by its own clock from when it arrived: setting the clock either way
/// only ends it sooner.
public struct ParentUnlock: Codable, Sendable, Hashable {
    /// How long an unlock lasts.
    public static let minutes = 15
    /// What a parent's phone may ask for.
    public static let allowedMinutes = 1...60

    /// The parent's name, as on grants.
    public var by: String
    public var at: Date
    public var until: Date

    public init(by: String, at: Date, minutes: Int = ParentUnlock.minutes) {
        self.by = by
        self.at = at
        let minutes = min(max(minutes, Self.allowedMinutes.lowerBound), Self.allowedMinutes.upperBound)
        self.until = at.addingTimeInterval(Double(minutes) * 60)
    }

    public func isActive(at now: Date) -> Bool {
        at <= now && now < until
    }
}

public enum ParentControls {
    /// Whether a kid phone's parent controls are open. Before the phone has the family's link key no parent's phone
    /// could unlock them, so they stay open for first setup; single-phone test mode has no parent's phone either.
    public static func areOpen(hasLinkKey: Bool, testMode: Bool, unlock: ParentUnlock?, now: Date) -> Bool {
        !hasLinkKey || testMode || unlock?.isActive(at: now) == true
    }
}

/// Parent controls over the nearby link. Sent at once rather than every 15 s, and never filtered.
public enum LinkUnlock: Codable, Sendable, Hashable {
    /// Parent → kid: unlock for `minutes` of the kid phone's clock. `by`: the parent's name.
    case unlock(minutes: Int, by: String)
    /// Parent → kid: lock now.
    case lock
    /// Kid → parent: unlocked until then by the kid phone's clock, or locked (nil).
    case state(until: Date?)
}
