import DeviceActivity
import Foundation
import ManagedSettings
import ThymeCore

/// Applies ScreenThyme's policy on the kid's phone (PLAN.md §15.2): ManagedSettings stores for restrictions, Downtime
/// and limits, and DeviceActivity activities whose callbacks call `reconcile`. Runs in the app and the extension,
/// one at a time.
enum Enforcer {
    static let downtimePrefix = "dt."
    static let limitPrefix = "lim."
    /// iOS allows 20 activities per app; the wake alarm needs one.
    static let maxActivities = 19

    // MARK: - Reconcile

    /// Recomputes what should be blocked now and applies it. `endingWindows`: Downtime windows whose last interval
    /// just ended. Returns the plan.
    @discardableResult
    static func reconcile(now: Date = Date(), endingWindows: Set<UUID> = [], recording change: ((inout EnforcementDayState) -> Void)? = nil)
        -> EnforcementPlan? {
        let config = SharedConfig.load()
        guard config.role == .kid, let kid = config.kid else { return nil }
        return AppGroup.withLock("enforcer") {
            var state = loadState(now: now)
            change?(&state)
            AppGroup.save(state, to: AppGroup.enforcementStateURL)
            let policy = AppGroup.loadPolicy() ?? Policy(kidID: kid.id, enabled: false)
            let items = Dictionary(AppGroup.loadItems().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let usage = Sampler.todayUsage(kid: kid, now: now)
            let plan = EnforcementPlanner.plan(policy: policy, items: items, usage: usage, state: state, now: now,
                                               endingWindows: endingWindows)
            apply(plan, policy: policy, items: items)
            AppGroup.save(AppliedPlan(plan: plan, at: now, limitNames: Dictionary(policy.limits.map { ($0.id, $0.name) },
                                                                                  uniquingKeysWith: { a, _ in a })),
                          to: AppGroup.enforcementURL)
            registerActivities(policy: policy, plan: plan, items: items)
            return plan
        }
    }

    static func loadState(now: Date = Date()) -> EnforcementDayState {
        let today = DayKey(now)
        guard let state = AppGroup.load(EnforcementDayState.self, from: AppGroup.enforcementStateURL), state.day == today
        else { return EnforcementDayState(day: today) }
        return state
    }

    static func loadApplied() -> AppliedPlan? {
        AppGroup.load(AppliedPlan.self, from: AppGroup.enforcementURL)
    }

    /// A limit's threshold event fired: remember it at that budget (Apple's data can lag a minute behind).
    static func limitFired(_ eventName: String, now: Date = Date()) {
        guard let (limitID, budget) = parseLimitEvent(eventName) else { return }
        reconcile(now: now) { $0.limitFires[limitID] = budget }
    }

    /// Records a parent's answer and applies it.
    static func apply(_ grant: TimeGrant, now: Date = Date()) {
        let config = SharedConfig.load()
        guard let kid = config.kid else { return }
        let usage = Sampler.todayUsage(kid: kid, now: now)
        let windowStart = loadApplied()?.plan.downtime?.interval.start
        reconcile(now: now) { state in
            guard !state.grants.contains(where: { $0.grant.requestID == grant.requestID }) else { return }
            let baseline = grant.itemID.flatMap { usage[$0] } ?? 0
            state.grants.append(AppliedGrant(grant: grant, appliedAt: now, baselineSeconds: baseline, windowStart: windowStart))
            try? AppGroup.journal.append(.note("grant \(grant.approved ? "approved" : "declined"): \(grant.minutes.map { "\($0) min" } ?? "rest of day")"))
        }
    }

    // MARK: - Stores

    /// Never blocked by Downtime or category limits, as with Apple's Screen Time: ScreenThyme itself (to ask for more
    /// time and see the answer) and Phone.
    static let exemptBundleIDs: Set<String> = ["com.danfoygel.screenthyme", "com.apple.mobilephone"]

    private static func apply(_ plan: EnforcementPlan, policy: Policy, items: [UUID: TrackedItem]) {
        let tokens = Tokens(items: items)
        let exempt = Set(items.values.filter { $0.kind == .app && exemptBundleIDs.contains($0.identifier) }.map(\.id))

        let restrictions = ManagedSettingsStore(named: .init("restrictions"))
        if policy.enabled {
            apply(policy.restrictions, to: restrictions)
        } else {
            restrictions.clearAllSettings()
        }
        let blocked = tokens.split(plan.blockedItems)
        restrictions.shield.applications = blocked.apps.isEmpty ? nil : blocked.apps
        restrictions.shield.webDomains = blocked.domains.isEmpty ? nil : blocked.domains
        restrictions.shield.applicationCategories = blocked.categories.isEmpty ? nil : .specific(blocked.categories)
        restrictions.shield.webDomainCategories = blocked.categories.isEmpty ? nil : .specific(blocked.categories)

        let downtime = ManagedSettingsStore(named: .init("downtime"))
        if plan.downtime != nil {
            let allowed = tokens.split(tokens.expandingCategories(plan.downtimeExceptions).union(exempt))
            downtime.shield.applicationCategories = .all(except: allowed.apps)
            downtime.shield.webDomainCategories = .all(except: allowed.domains)
        } else {
            downtime.clearAllSettings()
        }

        let limits = ManagedSettingsStore(named: .init("limits"))
        if plan.limitedItems.isEmpty {
            limits.clearAllSettings()
        } else {
            let limited = tokens.split(plan.limitedItems)
            let allowed = tokens.split(tokens.expandingCategories(plan.alwaysAllowed).union(exempt))
            limits.shield.applications = limited.apps.isEmpty ? nil : limited.apps
            limits.shield.webDomains = limited.domains.isEmpty ? nil : limited.domains
            limits.shield.applicationCategories = limited.categories.isEmpty ? nil : .specific(limited.categories, except: allowed.apps)
            limits.shield.webDomainCategories = limited.categories.isEmpty ? nil : .specific(limited.categories, except: allowed.domains)
        }
    }

    private static func apply(_ r: Restrictions, to store: ManagedSettingsStore) {
        func flag(_ value: Bool) -> Bool? { value ? true : nil }
        store.application.denyAppInstallation = flag(r.denyAppInstallation)
        store.application.denyAppRemoval = flag(r.denyAppRemoval)
        store.appStore.denyInAppPurchases = flag(r.denyInAppPurchases)
        store.appStore.requirePasswordForPurchases = flag(r.requirePasswordForPurchases)
        store.appStore.maximumRating = r.maximumAppRating
        store.media.denyExplicitContent = flag(r.denyExplicitContent)
        store.media.maximumMovieRating = r.maximumMovieRating
        store.media.maximumTVShowRating = r.maximumTVShowRating
        store.media.denyBookstoreErotica = flag(r.denyBookstoreErotica)
        store.media.denyMusicService = flag(r.denyMusicService)
        switch r.webFilter {
        case .unrestricted:
            store.webContent.blockedByFilter = nil
        case let .limitAdult(allowed, blocked):
            store.webContent.blockedByFilter = .auto(Set(blocked.map { WebDomain(domain: $0) }),
                                                     except: Set(allowed.map { WebDomain(domain: $0) }))
        case let .allowedOnly(allowed):
            store.webContent.blockedByFilter = .all(except: Set(allowed.map { WebDomain(domain: $0) }))
        }
        store.siri.denySiri = flag(r.denySiri)
        store.gameCenter.denyMultiplayerGaming = flag(r.denyMultiplayerGaming)
        store.gameCenter.denyAddingFriends = flag(r.denyAddingFriends)
        store.account.lockAccounts = flag(r.lockAccounts)
        store.passcode.lockPasscode = flag(r.lockPasscode)
        store.cellular.lockAppCellularData = flag(r.lockAppCellularData)
        store.cellular.lockCellularPlan = flag(r.lockCellularPlan)
        store.cellular.lockESIM = flag(r.lockESIM)
        store.dateAndTime.requireAutomaticDateAndTime = flag(r.requireAutomaticDateAndTime)
        store.safari.denyAutoFill = flag(r.denySafariAutoFill)
    }

    /// Item ids → the tokens shields take.
    private struct Tokens {
        let items: [UUID: TrackedItem]

        struct Split {
            var apps: Set<ApplicationToken> = []
            var domains: Set<WebDomainToken> = []
            var categories: Set<ActivityCategoryToken> = []
        }

        func split(_ ids: Set<UUID>) -> Split {
            var split = Split()
            for id in ids {
                guard let item = items[id] else { continue }
                switch item.kind {
                case .app: TokenCoding.application(item.tokenData).map { _ = split.apps.insert($0) }
                case .domain: TokenCoding.webDomain(item.tokenData).map { _ = split.domains.insert($0) }
                case .category: TokenCoding.category(item.tokenData).map { _ = split.categories.insert($0) }
                }
            }
            return split
        }

        /// Categories replaced by their known apps and websites (for "all except" lists, which take apps only).
        func expandingCategories(_ ids: Set<UUID>) -> Set<UUID> {
            let categories = Set(ids.compactMap { items[$0] }.filter { $0.kind == .category }.map(\.identifier))
            guard !categories.isEmpty else { return ids }
            let members = items.values.filter { $0.category.map(categories.contains) == true }.map(\.id)
            return ids.union(members)
        }
    }

    // MARK: - Activities

    /// One activity per Downtime interval (`dt.<id8>`, split `.a`/`.b` across midnight) and per limit
    /// (`lim.<id8>`, one event `lim.<id8>.<budget>`). Re-registers only what changed: every registration replays
    /// passed thresholds.
    private static func registerActivities(policy: Policy, plan: EnforcementPlan, items: [UUID: TrackedItem]) {
        var desired: [String: (signature: String, register: (DeviceActivityCenter) throws -> Void)] = [:]
        if policy.enabled {
            for window in policy.downtime {
                for (suffix, start, end) in segments(of: window) where end - start >= 15 {
                    let name = downtimePrefix + short(window.id) + suffix
                    desired[name] = ("\(start)-\(end)", { center in
                        try center.startMonitoring(DeviceActivityName(name), during: schedule(start, end))
                    })
                }
            }
            let tokens = Tokens(items: items)
            for limit in policy.limits where limit.enabled {
                guard let budget = plan.budgets[limit.id] else { continue }
                let name = limitPrefix + short(limit.id)
                let targets = tokens.split(limit.items.subtracting(policy.alwaysAllowed))
                let event = DeviceActivityEvent(applications: targets.apps, categories: targets.categories,
                                                webDomains: targets.domains, threshold: DateComponents(minute: budget),
                                                includesPastActivity: true)
                let signature = "\(budget)|\(limit.items.map(\.uuidString).sorted().joined(separator: ","))"
                desired[name] = (signature, { center in
                    try center.startMonitoring(DeviceActivityName(name), during: schedule(0, 23 * 60 + 59),
                                               events: [DeviceActivityEvent.Name(name + ".\(budget)"): event])
                })
            }
        }
        let registered = AppGroup.load([String: String].self, from: AppGroup.enforcementActivitiesURL) ?? [:]
        let center = DeviceActivityCenter()
        let active = Set(center.activities.map(\.rawValue))
        let stale = registered.keys.filter { desired[$0] == nil }
            + active.filter { ($0.hasPrefix(downtimePrefix) || $0.hasPrefix(limitPrefix)) && desired[$0] == nil }
        if !stale.isEmpty {  // never an empty list: that stops every activity
            center.stopMonitoring(Set(stale).map { DeviceActivityName($0) })
        }
        var now: [String: String] = [:]
        for (name, entry) in desired.sorted(by: { $0.key < $1.key }).prefix(maxActivities) {
            if registered[name] == entry.signature, active.contains(name) {
                now[name] = entry.signature
                continue
            }
            do {
                try entry.register(center)
                now[name] = entry.signature
            } catch {
                try? AppGroup.journal.append(.note("enforcer: \(name) failed: \(error)"))
            }
        }
        if desired.count > maxActivities {
            try? AppGroup.journal.append(.note("enforcer: \(desired.count) activities wanted, \(maxActivities) allowed"))
        }
        if now != registered { AppGroup.save(now, to: AppGroup.enforcementActivitiesURL) }
    }

    /// Forgets what was registered, so the next reconcile registers everything (after iOS stopped all monitoring).
    static func forgetActivities() {
        try? FileManager.default.removeItem(at: AppGroup.enforcementActivitiesURL)
    }

    private static func segments(of window: DowntimeWindow) -> [(String, Int, Int)] {
        let lastMinute = 23 * 60 + 59
        guard window.endMinute < window.startMinute else { return [("", window.startMinute, window.endMinute)] }
        return [(".a", window.startMinute, lastMinute), (".b", 0, window.endMinute)]
    }

    private static func schedule(_ start: Int, _ end: Int) -> DeviceActivitySchedule {
        DeviceActivitySchedule(intervalStart: DateComponents(hour: start / 60, minute: start % 60),
                               intervalEnd: DateComponents(hour: end / 60, minute: end % 60), repeats: true)
    }

    static func short(_ id: UUID) -> String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    // MARK: - Callbacks

    /// The Downtime window whose final interval `activity` is ("dt.<id8>" or "dt.<id8>.b"), if any.
    static func endingWindow(for activity: String) -> UUID? {
        guard activity.hasPrefix(downtimePrefix), !activity.hasSuffix(".a") else { return nil }
        let id8 = activity.dropFirst(downtimePrefix.count).prefix(8)
        return AppGroup.loadPolicy()?.downtime.first { short($0.id) == id8 }?.id
    }

    static func parseLimitEvent(_ name: String) -> (UUID, Int)? {
        let parts = name.split(separator: ".")
        guard parts.count == 3, parts[0] == "lim", let budget = Int(parts[2]),
              let limit = AppGroup.loadPolicy()?.limits.first(where: { short($0.id) == parts[1] }) else { return nil }
        return (limit.id, budget)
    }
}
