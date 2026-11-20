import Foundation

/// What one app's or website's details screen shows, on parents' phones and the kid's: the parts of the kid's policy
/// that reach it, its use over the last month, and the kid's requests for more time and one more minute for it.
/// A matched app is two items (`TokenPairing`): Apple's, with a bundle ID and usage, and the scan's, with a token,
/// which the policy names. The details cover both, and the app's category.
public struct AppDetails: Sendable {
    /// How a part of the policy reaches the app.
    public enum Via: Sendable, Hashable {
        /// It names the app itself.
        case item
        /// Through one of the parents' groups (`ItemGroup` id), which holds the app or its category.
        case group(UUID)
        /// Through Apple's category (`TrackedItem` id).
        case category(UUID)
        /// A whole-phone Downtime window or an all-apps limit.
        case everything
    }

    public struct Downtime: Sendable, Hashable {
        public var window: DowntimeWindow
        public var via: [Via]
    }

    public struct Limit: Sendable, Hashable {
        public var limit: AppLimit
        public var via: [Via]
    }

    /// The item asked about.
    public var item: TrackedItem
    /// The item, its match and every scanned item matched to the same app.
    public var ids: Set<UUID>
    /// Apple's item, whose use is reported; nil for a scanned item not matched yet.
    public var usageItem: TrackedItem?
    /// A scanned item with a token, which shields can name; nil for an app the scan hasn't been matched to.
    public var tokenItem: TrackedItem?
    /// Apple's category ("Games"), as the app's use reports it.
    public var categoryName: String?
    /// Category items for `categoryName`: Apple's and scanned ones matched to it.
    public var categoryIDs: Set<UUID>
    /// The parents' groups that hold the app or its category.
    public var groups: [ItemGroup]
    public var alwaysAllowed: [Via]
    public var blocked: [Via]
    /// Downtime windows that cover it, in the policy's order. Whole-phone windows are left out for Always Allowed apps.
    public var downtime: [Downtime]
    /// Limits that count it, in the policy's order. All-apps limits are left out for Always Allowed apps.
    public var limits: [Limit]
    /// ScreenThyme itself and Phone, which Downtime and limits never block.
    public var isExempt: Bool

    /// - Parameter exempt: apps never blocked (`Enforcer.exemptItems`).
    public init(item: TrackedItem, items: [UUID: TrackedItem], policy: Policy, exempt: Set<UUID> = []) {
        self.item = item
        let match = item.isScanned ? item.match.flatMap { items[$0] } : item
        let scanned = match.map { match in items.values.filter { $0.isScanned && $0.match == match.id } } ?? []
        let ids = Set([item.id] + (match.map { [$0.id] } ?? []) + scanned.map(\.id))
        let categoryName = match?.category ?? item.category
        let categoryIDs = categoryName.map { name in
            Set(items.values.filter { candidate in
                candidate.kind == .category && (candidate.match.flatMap { items[$0] }?.identifier ?? candidate.identifier) == name
            }.map(\.id))
        } ?? []
        let groups = policy.groups.filter { !$0.items.isDisjoint(with: ids.union(categoryIDs)) }
        func via(_ targets: Set<UUID>) -> [Via] {
            var result: [Via] = []
            if !targets.isDisjoint(with: ids) { result.append(.item) }
            for group in groups where targets.contains(group.id) { result.append(.group(group.id)) }
            for id in categoryIDs.sorted(by: { $0.uuidString < $1.uuidString }) where targets.contains(id) {
                result.append(.category(id))
            }
            return result
        }
        let isExempt = !ids.isDisjoint(with: exempt)
        let alwaysAllowed = via(policy.alwaysAllowed)
        let allowed = isExempt || !alwaysAllowed.isEmpty

        self.usageItem = match
        self.ids = ids
        tokenItem = item.tokenData != nil ? item
            : scanned.filter { $0.tokenData != nil }.min { $0.id.uuidString < $1.id.uuidString }
        self.categoryName = categoryName
        self.categoryIDs = categoryIDs
        self.groups = groups
        self.isExempt = isExempt
        self.alwaysAllowed = alwaysAllowed
        blocked = via(policy.blocked)
        downtime = policy.downtime.compactMap { window in
            if window.isWholePhone { return allowed ? nil : Downtime(window: window, via: [.everything]) }
            let reached = via(window.items)
            return reached.isEmpty ? nil : Downtime(window: window, via: reached)
        }
        limits = policy.limits.compactMap { limit in
            if limit.allApps { return allowed ? nil : Limit(limit: limit, via: [.everything]) }
            let reached = via(limit.items)
            return reached.isEmpty ? nil : Limit(limit: limit, via: reached)
        }
    }

    /// How `group` reaches the app: holding it, its category, or both.
    public func via(_ group: ItemGroup) -> [Via] {
        (group.items.isDisjoint(with: ids) ? [] : [Via.item])
            + categoryIDs.filter(group.items.contains).sorted { $0.uuidString < $1.uuidString }.map(Via.category)
    }

    /// Always Allowed (or ScreenThyme or Phone): Downtime and limits let it through.
    public var isAlwaysAllowed: Bool { isExempt || !alwaysAllowed.isEmpty }

    // MARK: - Now

    public enum Status: Sendable, Hashable {
        /// The kid's policy is off.
        case notEnforced
        case open
        case downtime(name: String, until: Date)
        case limit(name: String)
        case blocked
    }

    /// Whether `plan` blocks the app now, and why, in the order the block page gives: Downtime first, then limits,
    /// then always blocked.
    public func status(in plan: EnforcementPlan, policy: Policy) -> Status {
        guard policy.enabled else { return .notEnforced }
        guard !isExempt else { return .open }
        let reach = ids.union(categoryIDs)
        if let downtime = plan.downtime, reach.isDisjoint(with: plan.downtimeExceptions) {
            return .downtime(name: downtime.name, until: downtime.interval.end)
        }
        for downtime in plan.scopedDowntime
        where !downtime.items.isDisjoint(with: reach) && downtime.exceptions.isDisjoint(with: reach) {
            return .downtime(name: downtime.name, until: downtime.interval.end)
        }
        if let limit = limitReached(in: plan, policy: policy) { return .limit(name: limit.name) }
        return plan.blockedItems.isDisjoint(with: reach) ? .open : .blocked
    }

    /// The first used-up limit in `plan` that shields the app, whatever Downtime does. A plan for the last moment of an
    /// earlier day gives the limit the app went over that day.
    public func limitReached(in plan: EnforcementPlan, policy: Policy) -> AppLimit? {
        guard policy.enabled, !isExempt else { return nil }
        let reach = ids.union(categoryIDs)
        return policy.resolved.limits.first { limit in
            plan.exhaustedLimits.contains(limit.id)
                && (limit.allApps ? plan.allAppsLimited && !isAlwaysAllowed : !plan.limitedItems.isDisjoint(with: reach))
        }
    }

    // MARK: - Usage

    public struct DayUse: Sendable, Hashable {
        public var day: DayKey
        public var seconds: Double
        /// The phone reported any use that day: a day without is unknown, not unused.
        public var reported: Bool
    }

    public struct Usage: Sendable, Hashable {
        /// The last 30 days, oldest first, ending today.
        public var days: [DayUse]
        public var lastUsed: Date?

        public var today: Double { days.last?.seconds ?? 0 }
        public var yesterday: Double { days.dropLast().last?.seconds ?? 0 }
        public var last7Days: Double { days.suffix(7).reduce(0) { $0 + $1.seconds } }
        public var last30Days: Double { days.reduce(0) { $0 + $1.seconds } }
        /// Days before today the phone reported on.
        public var reportedDays: Int { days.dropLast().filter(\.reported).count }
        /// Per day reported before today (today isn't over); nil before there's one.
        public var dailyAverage: Double? {
            reportedDays == 0 ? nil : days.dropLast().reduce(0) { $0 + $1.seconds } / Double(reportedDays)
        }
    }

    public static let usageDays = 30

    /// The app's use from each day's samples (all the kid's, any app).
    public func usage(today: DayKey, calendar: Calendar = .current, samples: (DayKey) -> [UsageSample]) -> Usage {
        var lastUsed: Date?
        let days = (0..<Self.usageDays).reversed().map { back in
            let day = today.adding(days: -back, calendar: calendar)
            let all = samples(day)
            let own = all.filter { ids.contains($0.itemID) && $0.seconds > 0 }
            if let end = own.map(\.end).max(), end > (lastUsed ?? .distantPast) { lastUsed = end }
            return DayUse(day: day, seconds: own.reduce(0) { $0 + $1.seconds }, reported: !all.isEmpty)
        }
        return Usage(days: days, lastUsed: lastUsed)
    }

    /// Seconds per item from a day's samples, with scanned items repeating their match's, as the planner counts.
    public static func usage(_ samples: [UsageSample], items: [UUID: TrackedItem]) -> [UUID: Double] {
        var usage: [UUID: Double] = [:]
        for sample in samples { usage[sample.itemID, default: 0] += sample.seconds }
        for item in items.values {
            if item.isScanned, let match = item.match, let seconds = usage[match] { usage[item.id] = seconds }
        }
        return usage
    }

    // MARK: - Requests

    public enum Request: Sendable, Hashable, Identifiable {
        /// Asked a parent; the answer, once there is one.
        case asked(TimeRequest, TimeGrant?)
        case extraMinute(ExtraMinuteUse)

        public var id: UUID {
            switch self {
            case let .asked(request, _): request.id
            case let .extraMinute(use): use.id
            }
        }

        public var at: Date {
            switch self {
            case let .asked(request, _): request.at
            case let .extraMinute(use): use.at
            }
        }

        /// What it named: the app, its category, or nothing (the whole phone).
        public var itemID: UUID? {
            switch self {
            case let .asked(request, _): request.itemID
            case let .extraMinute(use): use.itemID
            }
        }
    }

    /// Requests for more time and one more minute since `since` that reach the app, newest first: for the app or its
    /// category, for time on a limit that counts it (whichever app the kid asked from), and for the whole phone during
    /// Downtime that covers it. One more minute on a limit lets through only the app pressed, or for an all-apps limit
    /// the whole phone.
    public func requests(_ requests: [TimeRequest], grants: [TimeGrant], extraMinutes: [ExtraMinuteUse],
                         since: Date) -> [Request] {
        let answers = Dictionary(grants.map { ($0.requestID, $0) }, uniquingKeysWith: { a, b in a.at > b.at ? a : b })
        let asked = requests.filter { $0.at >= since && reaches($0.reason, itemID: $0.itemID, limit: { _ in true }) }
            .map { Request.asked($0, answers[$0.id]) }
        let minutes = extraMinutes.filter { $0.at >= since && reaches($0.reason, itemID: $0.itemID, limit: \.allApps) }
            .map(Request.extraMinute)
        return (asked + minutes).sorted { ($0.at, $0.id.uuidString) > ($1.at, $1.id.uuidString) }
    }

    /// Whether a request for `reason` reaches the app: it names the app or its category, it's for a limit that counts
    /// the app and `limit` accepts, or it's for the whole phone during Downtime that covers the app.
    private func reaches(_ reason: BlockReason, itemID: UUID?, limit accepts: (AppLimit) -> Bool) -> Bool {
        if let itemID, ids.contains(itemID) || categoryIDs.contains(itemID) { return true }
        switch reason {
        case let .limit(id): return limits.contains { $0.limit.id == id && accepts($0.limit) }
        case let .downtime(id): return itemID == nil && downtime.contains { $0.window.id == id }
        case .blocked: return false
        }
    }

    /// The parents' alert rules for this app's daily use.
    public func alertRules(_ rules: [Rule]) -> [Rule] {
        rules.filter { rule in
            if case let .dailyThreshold(itemID?, _) = rule.condition { ids.contains(itemID) } else { false }
        }
    }
}
