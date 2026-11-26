import Foundation

/// Mandatory breaks on the kid's phone (PLAN.md §15.13): follows the day's counted use, wake by wake, and starts a break
/// once a stretch of use reaches the rule's minutes. A stretch ends only with a rest of the break's own length: shorter
/// gaps don't start the count over. Wakes come with use (the wake alarm) and with the break's end (`brk.end`), so a gap
/// is the clock time between two wakes that saw the counted use grow.
public struct BreakTracker: Codable, Sendable, Hashable {
    /// The counted use (seconds today) when the current stretch began; nil with no stretch.
    public var stretchStartSeconds: Double?
    /// The counted use at the last wake.
    public var lastSeconds: Double = 0
    /// The last wake that saw the counted use grow.
    public var lastUseAt: Date?
    /// The break that's on or last was: its start and end.
    public var breakStart: Date?
    public var breakUntil: Date?

    public init() {}

    /// A break is on at `now`.
    public func isOnBreak(at now: Date) -> Bool {
        breakUntil.map { now < $0 } ?? false
    }

    /// Seconds of use in the current stretch, as of the last wake.
    public var stretchSeconds: Double {
        stretchStartSeconds.map { max(0, lastSeconds - $0) } ?? 0
    }

    /// Takes in a wake: `counted` is today's use as breaks count it. Returns true when a break starts.
    @discardableResult
    public mutating func observe(counted: Double, at now: Date, rule: BreakRule?) -> Bool {
        guard let rule, rule.enabled, rule.useMinutes > 0, rule.breakMinutes > 0 else {
            self = BreakTracker()
            lastSeconds = counted
            return false
        }
        let rest = Double(rule.breakMinutes) * 60
        // Apple's count can restart lower (a new grant): keep the stretch's use as it was.
        if counted < lastSeconds, let start = stretchStartSeconds {
            stretchStartSeconds = max(0, start - (lastSeconds - counted))
        }
        defer { lastSeconds = counted }
        if let until = breakUntil {
            if now < until {
                // Use during a break (Always Allowed apart, it's what a grant let through) starts no stretch.
                if counted > lastSeconds { lastUseAt = now }
                return false
            }
            // The break was the rest: what follows is a new stretch.
            breakUntil = nil
            stretchStartSeconds = nil
        }
        // Less than a second: Apple's numbers rounding, not use.
        guard counted > lastSeconds + 1 else { return false }
        if stretchStartSeconds == nil || lastUseAt.map({ now.timeIntervalSince($0) >= rest }) ?? true {
            stretchStartSeconds = lastSeconds
        }
        lastUseAt = now
        guard counted - (stretchStartSeconds ?? counted) >= Double(rule.useMinutes) * 60 else { return false }
        breakStart = now
        breakUntil = now.addingTimeInterval(rest)
        stretchStartSeconds = nil
        return true
    }
}
