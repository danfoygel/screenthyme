import Foundation

/// A grant the kid's phone has applied, with what it needs to know when the grant runs out.
public struct AppliedGrant: Codable, Sendable, Hashable {
    public var grant: TimeGrant
    public var appliedAt: Date
    /// For grants that name an item: the item's use today when applied (the grant counts use after it). For a limit
    /// grant that names nothing: the limit's use when applied, which its minutes start from if the limit was past.
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
    /// Mandatory breaks: today's stretch of use and the break that's on (PLAN.md §15.13).
    public var breaks = BreakTracker()

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
        breaks = try container.decodeIfPresent(BreakTracker.self, forKey: .breaks) ?? BreakTracker()
    }

    /// One more minute is once a day per app, or with no app (a Downtime or all-apps limit shield, which names only a
    /// category) once per Downtime window or limit. A break's count starts again with each break.
    /// Never for apps that aren't allowed at all.
    public func canTakeExtraMinute(itemID: UUID?, reason: BlockReason) -> Bool {
        guard reason != .blocked else { return false }
        let since = reason == .breakTime ? breaks.breakStart ?? .distantPast : .distantPast
        return !extraMinutes.contains { taken in
            guard taken.reason != .breakTime || taken.at >= since else { return false }
            return if let itemID { taken.itemID == itemID } else { taken.itemID == nil && taken.reason == reason }
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

    /// A Downtime window for some apps that's on now (PLAN.md §15.8).
    public struct ScopedDowntime: Codable, Sendable, Hashable {
        public var windowID: UUID
        public var name: String
        public var interval: DateInterval
        /// Shielded: the window's apps, websites and categories, minus Always Allowed and what grants and one more
        /// minute let through (categories stay categories).
        public var items: Set<UUID>
        /// Let through the window's categories: Always Allowed plus grants and one more minute.
        public var exceptions: Set<UUID>
    }

    /// The whole-phone Downtime window that's on.
    public var downtime: Downtime?
    /// Items usable during Downtime: Always Allowed plus Downtime grants.
    public var downtimeExceptions: Set<UUID> = []
    /// Every Downtime window for some apps that's on, unless paused or all let through.
    public var scopedDowntime: [ScopedDowntime] = []
    /// Limit id → today's budget in minutes (limit plus grants that name no app); nil budget means unlimited today.
    public var budgets: [UUID: Int] = [:]
    /// Limit id → minutes used today.
    public var used: [UUID: Int] = [:]
    public var exhaustedLimits: Set<UUID> = []
    /// Items of exhausted limits, minus Always Allowed and what grants let through (categories stay categories).
    public var limitedItems: Set<UUID> = []
    /// An all-apps limit is exhausted: everything but Always Allowed is shielded.
    public var allAppsLimited = false
    /// Exhausted limit id → the apps (or categories) a parent's grant lets through it, while the grant has time left.
    public var limitPasses: [UUID: Set<UUID>] = [:]
    /// Passes every exhausted limit that counts them lets through: left out of limits' category and all-apps shields.
    public var limitExceptions: Set<UUID> = []
    /// Always blocked items, minus blocked-item grants.
    public var blockedItems: Set<UUID> = []
    /// Always Allowed items, also exempt from exhausted limits.
    public var alwaysAllowed: Set<UUID> = []
    /// When the first running "one more minute" ends: the kid's phone re-applies the plan then.
    public var extraMinuteEnds: Date?
    /// The mandatory break that's on (PLAN.md §15.13), unless a grant or one more minute lifts it: like whole-phone
    /// Downtime, everything but `breakExceptions` is shielded. The kid's phone re-applies the plan at its end.
    public var breakTime: DateInterval?
    /// Items usable during the break: Always Allowed plus break grants and one more minute.
    public var breakExceptions: Set<UUID> = []

    public init() {}

    /// Plans saved before a field existed still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        downtime = try container.decodeIfPresent(Downtime.self, forKey: .downtime)
        downtimeExceptions = try container.decodeIfPresent(Set<UUID>.self, forKey: .downtimeExceptions) ?? []
        scopedDowntime = try container.decodeIfPresent([ScopedDowntime].self, forKey: .scopedDowntime) ?? []
        budgets = try container.decodeIfPresent([UUID: Int].self, forKey: .budgets) ?? [:]
        used = try container.decodeIfPresent([UUID: Int].self, forKey: .used) ?? [:]
        exhaustedLimits = try container.decodeIfPresent(Set<UUID>.self, forKey: .exhaustedLimits) ?? []
        limitedItems = try container.decodeIfPresent(Set<UUID>.self, forKey: .limitedItems) ?? []
        allAppsLimited = try container.decodeIfPresent(Bool.self, forKey: .allAppsLimited) ?? false
        limitPasses = try container.decodeIfPresent([UUID: Set<UUID>].self, forKey: .limitPasses) ?? [:]
        limitExceptions = try container.decodeIfPresent(Set<UUID>.self, forKey: .limitExceptions) ?? []
        blockedItems = try container.decodeIfPresent(Set<UUID>.self, forKey: .blockedItems) ?? []
        alwaysAllowed = try container.decodeIfPresent(Set<UUID>.self, forKey: .alwaysAllowed) ?? []
        extraMinuteEnds = try container.decodeIfPresent(Date.self, forKey: .extraMinuteEnds)
        breakTime = try container.decodeIfPresent(DateInterval.self, forKey: .breakTime)
        breakExceptions = try container.decodeIfPresent(Set<UUID>.self, forKey: .breakExceptions) ?? []
    }

    /// The name and occurrence of Downtime window `id`, if it's on.
    public func downtime(_ id: UUID) -> (name: String, interval: DateInterval)? {
        if let downtime, downtime.windowID == id { return (downtime.name, downtime.interval) }
        return scopedDowntime.first { $0.windowID == id }.map { ($0.name, $0.interval) }
    }

    /// Something is blocked by Downtime now.
    public var hasDowntime: Bool { downtime != nil || !scopedDowntime.isEmpty }
}

public enum EnforcementPlanner {
    /// - Parameters:
    ///   - usage: seconds used today per app or website item (Apple's data).
    ///   - endingWindows: Downtime windows whose final interval just ended (DeviceActivity can call a moment early).
    ///   - exempt: apps whose use all-apps limits don't count: those never blocked (ScreenThyme itself, Phone), and
    ///     those whose use is Safari's on their website (`WebMirror`).
    public static func plan(policy: Policy, items: [UUID: TrackedItem], usage: [UUID: Double], state: EnforcementDayState,
                            now: Date, endingWindows: Set<UUID> = [], exempt: Set<UUID> = [],
                            calendar: Calendar = .current) -> EnforcementPlan {
        var plan = EnforcementPlan()
        guard policy.enabled else { return plan }
        let policy = policy.resolved(items: items)
        let today = DayKey(now, calendar: calendar)
        let grants = state.day == today ? state.grants.filter(\.grant.approved) : []
        let limitFires = state.day == today ? state.limitFires : [:]
        let extraMinutes = state.day == today ? state.extraMinutes.filter { $0.isActive(at: now) } : []
        plan.extraMinuteEnds = extraMinutes.map(\.until).min()
        plan.alwaysAllowed = policy.alwaysAllowed

        // Downtime for the whole phone: the first window that's on.
        for window in policy.downtime where window.isWholePhone && !endingWindows.contains(window.id) {
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

        // Downtime for some apps: every window that's on. Its shields name the app (or the category), so a grant or one
        // more minute lets that through; one with no item pauses the window.
        for window in policy.downtime where !endingWindows.contains(window.id) {
            guard let targets = policy.downtimeItems(window),
                  let interval = window.daily.occurrence(containing: now, calendar: calendar) else { continue }
            let reason = BlockReason.downtime(window.id)
            var scoped = EnforcementPlan.ScopedDowntime(windowID: window.id, name: window.name, interval: interval,
                                                        items: targets.subtracting(policy.alwaysAllowed),
                                                        exceptions: policy.alwaysAllowed)
            let passes = grants.filter { $0.grant.reason == reason && $0.windowStart == interval.start
                && isLeft($0, usage: usage, now: now) }.map(\.grant.itemID)
                + extraMinutes.filter { $0.reason == reason }.map(\.itemID)
            guard !passes.contains(nil) else { continue }
            for case let item? in passes {
                scoped.items.remove(item)
                scoped.exceptions.insert(item)
            }
            if !scoped.items.isEmpty { plan.scopedDowntime.append(scoped) }
        }

        // Limits. A grant that names an app (or a category) lets only that through the limit, for its minutes of use; one
        // that names nothing (an all-apps limit's category shield) raises the limit for everything it counts.
        let weekday = calendar.component(.weekday, from: now)
        for limit in policy.limits where limit.enabled {
            let used = Int(usedSeconds(limit, items: items, usage: usage, alwaysAllowed: policy.alwaysAllowed,
                                       exempt: exempt) / 60)
            plan.used[limit.id] = used
            guard let budget = Self.budget(for: limit.id, minutes: limit.minutes(on: weekday), grants: grants)
            else { continue }  // the rest of today
            plan.budgets[limit.id] = budget
            // iOS's event counts a category's Always Allowed apps too; then only our own count ends the limit.
            let fired = limitFires[limit.id] == budget
                && !eventCountsAlwaysAllowed(limit, items: items, alwaysAllowed: policy.alwaysAllowed)
            if used >= budget || fired {
                plan.exhaustedLimits.insert(limit.id)
                let passes = Set(grants.filter { $0.grant.reason == .limit(limit.id) && isLeft($0, usage: usage, now: now) }
                    .compactMap(\.grant.itemID))
                if !passes.isEmpty { plan.limitPasses[limit.id] = passes }
                if limit.allApps {
                    plan.allAppsLimited = true
                } else {
                    plan.limitedItems.formUnion(limit.items.subtracting(policy.alwaysAllowed).subtracting(passes))
                }
            }
        }
        // What every used-up limit that counts it lets through: categories and "all apps" shields leave these out.
        let exhausted = policy.limits.filter { plan.exhaustedLimits.contains($0.id) }
        for (limitID, passes) in plan.limitPasses {
            for item in passes where exhausted.allSatisfy({ other in
                other.id == limitID || plan.limitPasses[other.id]?.contains(item) == true
                    || !Self.counts(other, item: item, items: items, alwaysAllowed: policy.alwaysAllowed)
            }) {
                plan.limitExceptions.insert(item)
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

        // A mandatory break: a grant or one more minute that names an app lets it through; one that names nothing
        // (the shield names only a category) lifts the break while it has time left.
        if policy.breaks?.enabled == true, state.day == today, let start = state.breaks.breakStart,
           let until = state.breaks.breakUntil, start <= now, now < until {
            plan.breakTime = DateInterval(start: start, end: until)
            plan.breakExceptions = policy.alwaysAllowed
            let passes = grants.filter { $0.grant.reason == .breakTime && $0.appliedAt >= start
                && isLeft($0, usage: usage, now: now) }.map(\.grant.itemID)
                + extraMinutes.filter { $0.reason == .breakTime && $0.at >= start }.map(\.itemID)
            if passes.contains(nil) {
                plan.breakTime = nil
                plan.breakExceptions = []
            } else {
                plan.breakExceptions.formUnion(passes.compactMap { $0 })
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

    /// Takes in a wake for mandatory breaks (`BreakTracker`): today's use as all-apps limits count it, so Always
    /// Allowed and `exempt` apps don't count. Returns true when a break starts. Call it before `plan`.
    @discardableResult
    public static func trackBreaks(policy: Policy, items: [UUID: TrackedItem], usage: [UUID: Double],
                                   state: inout EnforcementDayState, now: Date, exempt: Set<UUID> = []) -> Bool {
        let rule = policy.enabled ? policy.breaks : nil
        let policy = policy.resolved(items: items)
        let counted = totalSeconds(items: items, usage: usage, excluding: policy.alwaysAllowed.union(exempt))
        return state.breaks.observe(counted: counted, at: now, rule: rule)
    }

    /// Whether `limit` counts `item` (an app, website or category, or a scanned one through its match): it's in the
    /// limit, in a category the limit holds, or the limit is for all apps. Always Allowed items count toward none.
    static func counts(_ limit: AppLimit, item: UUID, items: [UUID: TrackedItem], alwaysAllowed: Set<UUID>) -> Bool {
        let ids = Set([item, items[item]?.match].compactMap { $0 })
        guard ids.isDisjoint(with: alwaysAllowed) else { return false }
        if limit.allApps || !limit.items.isDisjoint(with: ids) { return true }
        let categories = categoryNames(limit.items, items: items)
        let own = ids.compactMap { items[$0] }.compactMap { $0.kind == .category ? $0.identifier : $0.category }
        return own.contains(where: categories.contains)
    }

    /// Whether iOS's threshold event for `limit` would count an Always Allowed app or website: one (or its match) in a
    /// category the limit holds. An event can't leave anything out of a category, so such a limit has none: the wake
    /// alarm's wakes (every minute of use) end it from our own count, which leaves Always Allowed out. Unmatched
    /// scanned apps have no known category and can't be seen here.
    public static func eventCountsAlwaysAllowed(_ limit: AppLimit, items: [UUID: TrackedItem],
                                                alwaysAllowed: Set<UUID>) -> Bool {
        guard !limit.allApps else { return false }
        let categories = categoryNames(limit.items, items: items)
        guard !categories.isEmpty else { return false }
        return alwaysAllowed.contains { id in
            [id, items[id]?.match].compactMap { $0 }.compactMap { items[$0] }
                .contains { $0.kind != .category && $0.category.map(categories.contains) == true }
        }
    }

    /// Minutes parents' approved `grants` add to limit `limitID`; nil when one gave the rest of the day. Only grants
    /// that name nothing raise the limit: one for an app lets that app through instead.
    public static func extraMinutes(for limitID: UUID, grants: some Sequence<TimeGrant>) -> Int? {
        var total = 0
        for grant in grants where raises(limitID, grant) {
            guard let minutes = addedMinutes(grant) else { return nil }
            total += minutes
        }
        return total
    }

    /// Today's budget for limit `limitID` of `minutes`, with what parents' applied grants that name nothing add; nil
    /// when one gave the rest of the day. Each grant's minutes count from the limit's use when it was applied, if that
    /// was past the budget so far: time given after the limit ran out is time from then, not from the limit.
    public static func budget(for limitID: UUID, minutes: Int, grants: some Sequence<AppliedGrant>) -> Int? {
        var budget = minutes
        for applied in grants.filter({ raises(limitID, $0.grant) }).sorted(by: { $0.appliedAt < $1.appliedAt }) {
            guard let added = addedMinutes(applied.grant) else { return nil }
            budget = max(budget, Int(applied.baselineSeconds / 60)) + added
        }
        return budget
    }

    /// A parent's approval that raises limit `limitID`: it names no app.
    static func raises(_ limitID: UUID, _ grant: TimeGrant) -> Bool {
        grant.approved && grant.reason == .limit(limitID) && grant.itemID == nil
    }

    /// The minutes a limit grant adds; nil for the rest of the day. One ended early adds only the minutes of the clock
    /// it ran, at most its own: no more use than that can have come from it.
    static func addedMinutes(_ grant: TimeGrant) -> Int? {
        if let ended = grant.endedAt {
            let ran = max(0, Int((ended.timeIntervalSince(grant.at) / 60).rounded(.up)))
            return min(grant.minutes ?? ran, ran)
        }
        return grant.minutes
    }

    /// Seconds `limit` counts: its apps, websites and categories, or for all apps everything but `exempt`; Always
    /// Allowed counts toward none. `limit` is from a resolved policy.
    public static func usedSeconds(_ limit: AppLimit, items: [UUID: TrackedItem], usage: [UUID: Double],
                                   alwaysAllowed: Set<UUID>, exempt: Set<UUID> = []) -> Double {
        limit.allApps
            ? totalSeconds(items: items, usage: usage, excluding: alwaysAllowed.union(exempt))
            : seconds(of: limit.items, items: items, usage: usage, excluding: alwaysAllowed)
    }

    /// The baseline a grant gets when applied (`AppliedGrant.baselineSeconds`): the use of the item it names, or for a
    /// limit grant that names nothing, the limit's use.
    public static func baseline(for grant: TimeGrant, policy: Policy, items: [UUID: TrackedItem], usage: [UUID: Double],
                                exempt: Set<UUID> = []) -> Double {
        if let item = grant.itemID { return usage[item] ?? 0 }
        guard case let .limit(limitID) = grant.reason else { return 0 }
        let policy = policy.resolved(items: items)
        guard let limit = policy.limits.first(where: { $0.id == limitID }) else { return 0 }
        return usedSeconds(limit, items: items, usage: usage, alwaysAllowed: policy.alwaysAllowed, exempt: exempt)
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
    /// whose use Apple's data doesn't report (always, for a grant until the window or day ends), unless a parent ended it.
    static func isLeft(_ applied: AppliedGrant, usage: [UUID: Double], now: Date) -> Bool {
        guard !applied.grant.isEnded(at: now) else { return false }
        guard let minutes = applied.grant.minutes else { return true }
        guard let item = applied.grant.itemID, let used = usage[item] else {
            return now < applied.appliedAt.addingTimeInterval(Double(minutes) * 60)
        }
        return used - applied.baselineSeconds < Double(minutes) * 60
    }
}
