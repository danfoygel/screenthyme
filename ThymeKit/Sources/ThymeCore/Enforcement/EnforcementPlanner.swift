import Foundation

/// A grant the kid's phone has applied, with what it needs to know when the grant runs out.
public struct AppliedGrant: Codable, Sendable, Hashable {
    public var grant: TimeGrant
    public var appliedAt: Date
    /// For Downtime and blocked-item grants: the item's use today when applied (the grant counts use after it).
    public var baselineSeconds: Double
    /// For Downtime grants: the start of the window occurrence the grant belongs to.
    public var windowStart: Date?

    public init(grant: TimeGrant, appliedAt: Date, baselineSeconds: Double = 0, windowStart: Date? = nil) {
        self.grant = grant
        self.appliedAt = appliedAt
        self.baselineSeconds = baselineSeconds
        self.windowStart = windowStart
    }
}

/// What the kid's phone remembers about enforcement today. Reset at each new day.
public struct EnforcementDayState: Codable, Sendable, Hashable {
    public var day: DayKey
    /// Limit id → the budget (minutes) at which its threshold event fired today.
    public var limitFires: [UUID: Int] = [:]
    public var grants: [AppliedGrant] = []

    public init(day: DayKey) {
        self.day = day
    }
}

/// What should be blocked now (PLAN.md §15.2). The Enforcer turns it into ManagedSettings stores.
public struct EnforcementPlan: Codable, Sendable, Hashable {
    public struct Downtime: Codable, Sendable, Hashable {
        public var windowID: UUID
        public var name: String
        public var interval: DateInterval
    }

    public var downtime: Downtime?
    /// Items usable during Downtime: Always Allowed plus Downtime grants.
    public var downtimeExceptions: Set<UUID> = []
    /// Limit id → today's budget in minutes (limit plus grants); nil budget means unlimited today.
    public var budgets: [UUID: Int] = [:]
    /// Limit id → minutes used today.
    public var used: [UUID: Int] = [:]
    public var exhaustedLimits: Set<UUID> = []
    /// Items of exhausted limits, minus Always Allowed (categories stay categories).
    public var limitedItems: Set<UUID> = []
    /// Always blocked items, minus blocked-item grants.
    public var blockedItems: Set<UUID> = []
    /// Always Allowed items, also exempt from exhausted limits.
    public var alwaysAllowed: Set<UUID> = []

    public init() {}
}

public enum EnforcementPlanner {
    /// - Parameters:
    ///   - usage: seconds used today per app or website item (Apple's data).
    ///   - endingWindows: Downtime windows whose final interval just ended (DeviceActivity can call a moment early).
    public static func plan(policy: Policy, items: [UUID: TrackedItem], usage: [UUID: Double], state: EnforcementDayState,
                            now: Date, endingWindows: Set<UUID> = [], calendar: Calendar = .current) -> EnforcementPlan {
        var plan = EnforcementPlan()
        guard policy.enabled else { return plan }
        let today = DayKey(now, calendar: calendar)
        let grants = state.day == today ? state.grants.filter(\.grant.approved) : []
        let limitFires = state.day == today ? state.limitFires : [:]
        plan.alwaysAllowed = policy.alwaysAllowed

        // Downtime.
        for window in policy.downtime where !endingWindows.contains(window.id) {
            guard let interval = window.daily.occurrence(containing: now, calendar: calendar) else { continue }
            plan.downtime = .init(windowID: window.id, name: window.name, interval: interval)
            break
        }
        plan.downtimeExceptions = policy.alwaysAllowed
        if let downtime = plan.downtime {
            for applied in grants {
                guard case let .downtime(windowID) = applied.grant.reason, windowID == downtime.windowID,
                      applied.windowStart == downtime.interval.start, let item = applied.grant.itemID else { continue }
                if isLeft(applied, usage: usage, now: now) { plan.downtimeExceptions.insert(item) }
            }
        }

        // Limits.
        let weekday = calendar.component(.weekday, from: now)
        for limit in policy.limits where limit.enabled {
            let extra = grants.filter { $0.grant.reason == .limit(limit.id) }.map(\.grant.minutes)
            let used = Int(seconds(of: limit.items, items: items, usage: usage, excluding: policy.alwaysAllowed) / 60)
            plan.used[limit.id] = used
            guard !extra.contains(nil) else { continue }  // the rest of today
            let budget = limit.minutes(on: weekday) + extra.compactMap { $0 }.reduce(0, +)
            plan.budgets[limit.id] = budget
            if used >= budget || limitFires[limit.id] == budget {
                plan.exhaustedLimits.insert(limit.id)
                plan.limitedItems.formUnion(limit.items.subtracting(policy.alwaysAllowed))
            }
        }

        // Blocked items.
        plan.blockedItems = policy.blocked
        for applied in grants {
            guard applied.grant.reason == .blocked, let item = applied.grant.itemID else { continue }
            if isLeft(applied, usage: usage, now: now) { plan.blockedItems.remove(item) }
        }
        return plan
    }

    /// Seconds used by `targets`: apps and websites directly, categories through their apps and websites, each once.
    public static func seconds(of targets: Set<UUID>, items: [UUID: TrackedItem], usage: [UUID: Double],
                               excluding excluded: Set<UUID> = []) -> Double {
        let categories = Set(targets.compactMap { items[$0] }.filter { $0.kind == .category }.map(\.identifier))
        var counted = Set<UUID>()
        for (id, _) in usage where !excluded.contains(id) {
            guard let item = items[id] else { continue }
            if targets.contains(id) || item.category.map(categories.contains) == true { counted.insert(id) }
        }
        return counted.reduce(0) { $0 + (usage[$1] ?? 0) }
    }

    /// A grant still has time left: minutes of the item's use, or of the clock for a scanned item, whose use Apple's
    /// data doesn't report (always, for a grant until the window or day ends).
    static func isLeft(_ applied: AppliedGrant, usage: [UUID: Double], now: Date) -> Bool {
        guard let minutes = applied.grant.minutes else { return true }
        guard let item = applied.grant.itemID else { return false }
        guard let used = usage[item] else { return now < applied.appliedAt.addingTimeInterval(Double(minutes) * 60) }
        return used - applied.baselineSeconds < Double(minutes) * 60
    }
}
