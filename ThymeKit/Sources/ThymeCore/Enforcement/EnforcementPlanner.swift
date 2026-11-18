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

/// "One more minute" from a block page (PLAN.md §15.5): the kid lets a blocked app through for a few minutes of the
/// clock (1 by default, up to 5, set on the kid's phone), without asking. `itemID` is what the press named: the app, or
/// for a category shield the category (a limit) or nothing (Downtime, which then pauses for the whole phone).
public struct ExtraMinute: Codable, Sendable, Hashable {
    public var itemID: UUID?
    public var reason: BlockReason
    public var at: Date
    public var until: Date

    /// How many minutes the kid may choose.
    public static let allowedMinutes = 1...5

    /// A stored setting brought into `allowedMinutes`; nil (never set) is 1.
    public static func minutes(_ setting: Int?) -> Int {
        min(max(setting ?? 1, allowedMinutes.lowerBound), allowedMinutes.upperBound)
    }

    public init(itemID: UUID?, reason: BlockReason, at: Date, minutes: Int = 1) {
        self.itemID = itemID
        self.reason = reason
        self.at = at
        self.until = at.addingTimeInterval(Double(Self.minutes(minutes)) * 60)
    }

    public func isActive(at now: Date) -> Bool {
        at <= now && now < until
    }
}

/// What the kid's phone remembers about enforcement today. Reset at each new day.
public struct EnforcementDayState: Codable, Sendable, Hashable {
    public var day: DayKey
    /// Limit id → the budget (minutes) at which its threshold event fired today.
    public var limitFires: [UUID: Int] = [:]
    public var grants: [AppliedGrant] = []
    public var extraMinutes: [ExtraMinute] = []

    public init(day: DayKey) {
        self.day = day
    }

    /// Files written before a field existed still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        day = try container.decode(DayKey.self, forKey: .day)
        limitFires = try container.decodeIfPresent([UUID: Int].self, forKey: .limitFires) ?? [:]
        grants = try container.decodeIfPresent([AppliedGrant].self, forKey: .grants) ?? []
        extraMinutes = try container.decodeIfPresent([ExtraMinute].self, forKey: .extraMinutes) ?? []
    }

    /// One more minute is once a day per app, or with no app (a Downtime or all-apps limit shield, which names only a
    /// category) once per Downtime window or limit.
    /// Never for apps that aren't allowed at all.
    public func canTakeExtraMinute(itemID: UUID?, reason: BlockReason) -> Bool {
        guard reason != .blocked else { return false }
        return !extraMinutes.contains { taken in
            if let itemID { taken.itemID == itemID } else { taken.itemID == nil && taken.reason == reason }
        }
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
    /// An all-apps limit is exhausted: everything but Always Allowed is shielded.
    public var allAppsLimited = false
    /// Always blocked items, minus blocked-item grants.
    public var blockedItems: Set<UUID> = []
    /// Always Allowed items, also exempt from exhausted limits.
    public var alwaysAllowed: Set<UUID> = []
    /// When the first running "one more minute" ends: the kid's phone re-applies the plan then.
    public var extraMinuteEnds: Date?

    public init() {}

    /// Plans saved before a field existed still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        downtime = try container.decodeIfPresent(Downtime.self, forKey: .downtime)
        downtimeExceptions = try container.decodeIfPresent(Set<UUID>.self, forKey: .downtimeExceptions) ?? []
        budgets = try container.decodeIfPresent([UUID: Int].self, forKey: .budgets) ?? [:]
        used = try container.decodeIfPresent([UUID: Int].self, forKey: .used) ?? [:]
        exhaustedLimits = try container.decodeIfPresent(Set<UUID>.self, forKey: .exhaustedLimits) ?? []
        limitedItems = try container.decodeIfPresent(Set<UUID>.self, forKey: .limitedItems) ?? []
        allAppsLimited = try container.decodeIfPresent(Bool.self, forKey: .allAppsLimited) ?? false
        blockedItems = try container.decodeIfPresent(Set<UUID>.self, forKey: .blockedItems) ?? []
        alwaysAllowed = try container.decodeIfPresent(Set<UUID>.self, forKey: .alwaysAllowed) ?? []
        extraMinuteEnds = try container.decodeIfPresent(Date.self, forKey: .extraMinuteEnds)
    }
}

public enum EnforcementPlanner {
    /// - Parameters:
    ///   - usage: seconds used today per app or website item (Apple's data).
    ///   - endingWindows: Downtime windows whose final interval just ended (DeviceActivity can call a moment early).
    ///   - exempt: apps never blocked (ScreenThyme itself, Phone), whose use all-apps limits don't count.
    public static func plan(policy: Policy, items: [UUID: TrackedItem], usage: [UUID: Double], state: EnforcementDayState,
                            now: Date, endingWindows: Set<UUID> = [], exempt: Set<UUID> = [],
                            calendar: Calendar = .current) -> EnforcementPlan {
        var plan = EnforcementPlan()
        guard policy.enabled else { return plan }
        let today = DayKey(now, calendar: calendar)
        let grants = state.day == today ? state.grants.filter(\.grant.approved) : []
        let limitFires = state.day == today ? state.limitFires : [:]
        let extraMinutes = state.day == today ? state.extraMinutes.filter { $0.isActive(at: now) } : []
        plan.extraMinuteEnds = extraMinutes.map(\.until).min()
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
                      applied.windowStart == downtime.interval.start, isLeft(applied, usage: usage, now: now) else { continue }
                if let item = applied.grant.itemID {
                    plan.downtimeExceptions.insert(item)
                } else {
                    // A request from a Downtime block page is for the whole phone: Downtime pauses.
                    plan.downtime = nil
                    break
                }
            }
        }
        if let downtime = plan.downtime {
            for minute in extraMinutes where minute.reason == .downtime(downtime.windowID) {
                if let item = minute.itemID { plan.downtimeExceptions.insert(item) } else { plan.downtime = nil }
            }
        }

        // Limits.
        let weekday = calendar.component(.weekday, from: now)
        for limit in policy.limits where limit.enabled {
            let extra = grants.filter { $0.grant.reason == .limit(limit.id) }.map(\.grant.minutes)
            let used = Int((limit.allApps
                ? totalSeconds(items: items, usage: usage, excluding: policy.alwaysAllowed.union(exempt))
                : seconds(of: limit.items, items: items, usage: usage, excluding: policy.alwaysAllowed)) / 60)
            plan.used[limit.id] = used
            guard !extra.contains(nil) else { continue }  // the rest of today
            let budget = limit.minutes(on: weekday) + extra.compactMap { $0 }.reduce(0, +)
            plan.budgets[limit.id] = budget
            if used >= budget || limitFires[limit.id] == budget {
                plan.exhaustedLimits.insert(limit.id)
                if limit.allApps {
                    plan.allAppsLimited = true
                } else {
                    plan.limitedItems.formUnion(limit.items.subtracting(policy.alwaysAllowed))
                }
            }
        }
        // One more minute lets the pressed item through every exhausted limit; the limit stays used up. An all-apps
        // limit's shield names only a category, so its minute is for the whole phone.
        for minute in extraMinutes {
            guard case let .limit(limitID) = minute.reason, plan.exhaustedLimits.contains(limitID) else { continue }
            if policy.limits.contains(where: { $0.id == limitID && $0.allApps }) {
                plan.allAppsLimited = false
            } else if let item = minute.itemID {
                plan.limitedItems.remove(item)
            } else if let limit = policy.limits.first(where: { $0.id == limitID }) {
                plan.limitedItems.subtract(limit.items)
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
    /// `excluded` apps and categories don't count, directly or through a scanned item matched to them.
    public static func seconds(of targets: Set<UUID>, items: [UUID: TrackedItem], usage: [UUID: Double],
                               excluding excluded: Set<UUID> = []) -> Double {
        let categories = categoryNames(targets, items: items)
        let excludedIDs = excluded.union(excluded.compactMap { items[$0]?.match })
        let excludedCategories = categoryNames(excluded, items: items)
        var counted = Set<UUID>()
        for (id, _) in usage {
            guard let item = items[id], !excludedIDs.contains(id),
                  item.category.map(excludedCategories.contains) != true else { continue }
            // A matched scanned item repeats its match's use: count it as the match, so it counts once.
            let own = item.isScanned ? item.match ?? id : id
            if targets.contains(id) || item.category.map(categories.contains) == true { counted.insert(own) }
        }
        return counted.reduce(0) { $0 + (usage[$1] ?? 0) }
    }

    /// The category names `ids` stand for, which apps and websites name in `TrackedItem.category`: a scanned category's
    /// is its match's, from Apple's data (`TokenPairing`).
    public static func categoryNames(_ ids: some Sequence<UUID>, items: [UUID: TrackedItem]) -> Set<String> {
        Set(ids.compactMap { items[$0] }.filter { $0.kind == .category }.map { item in
            item.match.flatMap { items[$0] }?.identifier ?? item.identifier
        })
    }

    /// Seconds of all use, for all-apps limits: Apple's per-app numbers except `excluded` apps (directly, through a
    /// scanned item matched to them, or through their category), minus excluded websites, which also count toward
    /// Safari. Scanned items only repeat their match's use, and websites aren't added, so nothing counts twice.
    public static func totalSeconds(items: [UUID: TrackedItem], usage: [UUID: Double], excluding excluded: Set<UUID> = [])
        -> Double {
        let excludedIDs = excluded.union(excluded.compactMap { items[$0]?.match })
        let excludedCategories = categoryNames(excluded, items: items)
        var apps = 0.0
        var excludedSites = 0.0
        for (id, seconds) in usage {
            guard let item = items[id], !item.isScanned else { continue }
            let isExcluded = excludedIDs.contains(id) || item.category.map(excludedCategories.contains) == true
            switch item.kind {
            case .app where !isExcluded: apps += seconds
            case .domain where isExcluded: excludedSites += seconds
            default: break
            }
        }
        return max(0, apps - excludedSites)
    }

    /// A grant still has time left: minutes of the item's use, or of the clock for the whole phone or a scanned item,
    /// whose use Apple's data doesn't report (always, for a grant until the window or day ends).
    static func isLeft(_ applied: AppliedGrant, usage: [UUID: Double], now: Date) -> Bool {
        guard let minutes = applied.grant.minutes else { return true }
        guard let item = applied.grant.itemID, let used = usage[item] else {
            return now < applied.appliedAt.addingTimeInterval(Double(minutes) * 60)
        }
        return used - applied.baselineSeconds < Double(minutes) * 60
    }
}
