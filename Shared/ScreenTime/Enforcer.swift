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
    /// Re-applies the plan when a "one more minute" runs out (PLAN.md §15.5).
    static let extraMinuteActivity = "om.end"
    /// iOS allows 20 activities per app; the wake alarm needs one, and the retired token matcher (`tm`) one until launch
    /// stops it.
    static let maxActivities = 18

    /// The Enforcer's activities, which the wake alarm's registration leaves alone.
    static func owns(_ activity: String) -> Bool {
        activity.hasPrefix(downtimePrefix) || activity.hasPrefix(limitPrefix) || activity == extraMinuteActivity
    }

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
            let items = Dictionary(AppGroup.loadItems().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let policy = (AppGroup.loadPolicy(now: now) ?? Policy(kidID: kid.id, enabled: false)).resolved(items: items)
            let usage = UsageSnapshot.todayUsage(kid: kid, now: now)
            clearRetiredStores(now: now)
            let plan = EnforcementPlanner.plan(policy: policy, items: items, usage: usage, state: state, now: now,
                                               endingWindows: endingWindows,
                                               exempt: exemptItems(items).union(webMirrored(items, now: now)))
            let unshielded = apply(plan, policy: policy, items: items, use: UsageSnapshot.todayUse(kid: kid, now: now))
            if unshielded.count != loadApplied()?.unshielded?.count ?? 0 {
                try? AppGroup.journal.append(.note("shields: \(unshielded.count) apps and sites past iOS's \(ShieldBudget.cap); shielding the ones used last"))
            }
            AppGroup.save(AppliedPlan(plan: plan, at: now, limitNames: Dictionary(policy.limits.map { ($0.id, $0.name) },
                                                                                  uniquingKeysWith: { a, _ in a }),
                                      unshielded: unshielded),
                          to: AppGroup.enforcementURL)
            registerActivities(policy: policy, plan: plan, items: items, now: now)
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

    /// Records a parent's answer (or the kid's own approval) and applies it, or a parent's end of one already applied
    /// (PLAN.md §15.12). False when there was nothing new.
    @discardableResult
    static func apply(_ grant: TimeGrant, now: Date = Date()) -> Bool {
        let config = SharedConfig.load()
        guard let kid = config.kid else { return false }
        let usage = UsageSnapshot.todayUsage(kid: kid, now: now)
        // The occurrence of the window it answers, even while Downtime is paused.
        var windowStart: Date?
        if case let .downtime(windowID) = grant.reason, let window = AppGroup.loadPolicy(now: now)?.downtime.first(where: { $0.id == windowID }) {
            windowStart = window.daily.occurrence(containing: now)?.start
        }
        var applied = false
        reconcile(now: now) { state in
            if let index = state.grants.firstIndex(where: { $0.grant.requestID == grant.requestID }) {
                guard let ended = grant.endedAt, state.grants[index].grant.endedAt == nil else { return }
                state.grants[index].grant = state.grants[index].grant.ending(at: ended, by: grant.endedBy ?? "A parent")
                applied = true
                try? AppGroup.grantHistory.append(state.grants[index].grant)
                try? AppGroup.journal.append(.note("grant ended early by \(grant.endedBy ?? "a parent")"))
                return
            }
            let baseline = grant.itemID.flatMap { usage[$0] } ?? 0
            state.grants.append(AppliedGrant(grant: grant, appliedAt: now, baselineSeconds: baseline, windowStart: windowStart))
            applied = true
            try? AppGroup.grantHistory.append(grant)
            let answer = grant.isSelfApproved ? "self-approved" : grant.approved ? "approved" : "declined"
            try? AppGroup.journal.append(.note("grant \(answer): \(grant.minutes.map { "\($0) min" } ?? "rest of day")"))
        }
        return applied
    }

    /// "One more minute" from a block page: lets `itemID` (or with none, what `reason` blocks) through for the kid
    /// phone's chosen number of minutes, once a day, and queues a note of it for the parents. False when it was
    /// already taken.
    @discardableResult
    static func takeExtraMinute(itemID: UUID?, reason: BlockReason, now: Date = Date()) -> Bool {
        let config = SharedConfig.load()
        let minutes = config.extraMinuteLength
        var taken = false
        reconcile(now: now) { state in
            guard state.canTakeExtraMinute(itemID: itemID, reason: reason) else { return }
            state.extraMinutes.append(ExtraMinute(itemID: itemID, reason: reason, at: now, minutes: minutes))
            taken = true
        }
        if taken, let kid = config.kid {
            try? AppGroup.extraMinuteUses.append(ExtraMinuteUse(kidID: kid.id, itemID: itemID, reason: reason, at: now,
                                                                minutes: minutes))
        }
        try? AppGroup.journal.append(.note(taken ? "one more minute (\(minutes) min): \(reason)" : "one more minute already used: \(reason)"))
        return taken
    }

    /// The extra-minute alarm: ends what is due (DeviceActivity can call a moment early) and re-applies the plan.
    static func endExtraMinutes(now: Date = Date()) {
        reconcile(now: now) { state in
            for index in state.extraMinutes.indices where state.extraMinutes[index].until <= now.addingTimeInterval(30) {
                state.extraMinutes[index].until = min(state.extraMinutes[index].until, now)
            }
        }
    }

    // MARK: - Stores

    /// Never blocked by Downtime or category limits, as with Apple's Screen Time: ScreenThyme itself (to ask for more
    /// time and see the answer) and Phone.
    static let exemptBundleIDs: Set<String> = ["com.danfoygel.screenthyme", "com.apple.mobilephone"]

    /// Apps whose use is Safari's on their website (`WebMirror`): all-apps limits count that time as Safari's.
    static func webMirrored(_ items: [UUID: TrackedItem], now: Date = Date()) -> Set<UUID> {
        AppGroup.load(WebMirror.self, from: AppGroup.webMirrorURL)?.mirrored(items: items, today: DayKey(now)) ?? []
    }

    static func exemptItems(_ items: [UUID: TrackedItem]) -> Set<UUID> {
        Set(items.values.filter { $0.kind == .app && exemptBundleIDs.contains($0.identifier) }.map(\.id))
    }

    /// Returns the apps and websites due a shield that iOS's cap left out.
    private static func apply(_ plan: EnforcementPlan, policy: Policy, items: [UUID: TrackedItem],
                              use: [UUID: ShieldBudget.Use]) -> Set<UUID> {
        let tokens = Tokens(items: items)
        let exempt = exemptItems(items)
        // ScreenThyme's own token, from the app scan. One app or none: more would let others through every shield.
        let picked = AppGroup.load([Data].self, from: AppGroup.exemptTokensURL) ?? []
        let exemptApps = picked.count == 1 ? Set(picked.compactMap(TokenCoding.application)) : []
        let allowedIDs = tokens.expandingCategories(plan.alwaysAllowed).union(exempt)
        var allowed = tokens.split(allowedIDs)
        allowed.apps.formUnion(exemptApps)

        // Apps and websites shielded one by one, within iOS's cap for all stores together.
        let exemptIDs = tokens.ids(of: exemptApps)
        let fitted = ShieldBudget.fit([plan.blockedItems.subtracting(exemptIDs),
                                       Set(plan.scopedDowntime.flatMap(\.items)).subtracting(allowedIDs).subtracting(exemptIDs),
                                       plan.limitedItems.subtracting(allowedIDs).subtracting(exemptIDs)],
                                      items: items, use: use)

        let restrictions = ManagedSettingsStore(named: .init("restrictions"))
        if policy.enabled {
            apply(policy.restrictions, to: restrictions)
        } else {
            restrictions.clearAllSettings()
        }
        var blocked = tokens.split(fitted.lists[0])
        blocked.apps.subtract(exemptApps)
        shieldOneByOne(blocked, in: restrictions)
        restrictions.shield.applicationCategories = blocked.categories.isEmpty ? nil
            : .specific(Tokens.capped(blocked.categories), except: Tokens.capped(exemptApps))
        restrictions.shield.webDomainCategories = blocked.categories.isEmpty ? nil : .specific(Tokens.capped(blocked.categories))

        // Every category but what's allowed: no list of apps, so no cap on how many it blocks.
        let downtime = ManagedSettingsStore(named: .init("downtime"))
        if plan.downtime != nil {
            var exceptions = tokens.split(tokens.expandingCategories(plan.downtimeExceptions).union(exempt))
            exceptions.apps.formUnion(exemptApps)
            downtime.shield.applicationCategories = .all(except: Tokens.capped(exceptions.apps))
            downtime.shield.webDomainCategories = .all(except: Tokens.capped(exceptions.domains))
        } else {
            downtime.clearAllSettings()
        }

        // Downtime for some apps (PLAN.md §15.8): their tokens, so the shield names the app; categories let through
        // what's allowed or granted in any window that's on.
        let someDowntime = ManagedSettingsStore(named: .init("downtime.some"))
        var some = tokens.split(fitted.lists[1])
        some.apps.subtract(allowed.apps)
        some.domains.subtract(allowed.domains)
        if plan.scopedDowntime.isEmpty { someDowntime.clearAllSettings() }
        shieldOneByOne(some, in: someDowntime)
        var someExceptions = tokens.split(tokens.expandingCategories(Set(plan.scopedDowntime.flatMap(\.exceptions))))
        someExceptions.apps.formUnion(allowed.apps)
        someExceptions.domains.formUnion(allowed.domains)
        someDowntime.shield.applicationCategories = some.categories.isEmpty ? nil
            : .specific(Tokens.capped(some.categories), except: Tokens.capped(someExceptions.apps))
        someDowntime.shield.webDomainCategories = some.categories.isEmpty ? nil
            : .specific(Tokens.capped(some.categories), except: Tokens.capped(someExceptions.domains))

        let limits = ManagedSettingsStore(named: .init("limits"))
        var limited = tokens.split(fitted.lists[2])
        limited.apps.subtract(allowed.apps)
        limited.domains.subtract(allowed.domains)
        if plan.limitedItems.isEmpty && !plan.allAppsLimited { limits.clearAllSettings() }
        shieldOneByOne(limited, in: limits)
        // What's allowed, and what parents' grants let through every used-up limit that counts it.
        var limitExceptions = tokens.split(tokens.expandingCategories(plan.limitExceptions))
        limitExceptions.apps.formUnion(allowed.apps)
        limitExceptions.domains.formUnion(allowed.domains)
        if plan.allAppsLimited {
            // Like Downtime: every category but what's allowed.
            limits.shield.applicationCategories = .all(except: Tokens.capped(limitExceptions.apps))
            limits.shield.webDomainCategories = .all(except: Tokens.capped(limitExceptions.domains))
        } else {
            limits.shield.applicationCategories = limited.categories.isEmpty ? nil
                : .specific(Tokens.capped(limited.categories), except: Tokens.capped(limitExceptions.apps))
            limits.shield.webDomainCategories = limited.categories.isEmpty ? nil
                : .specific(Tokens.capped(limited.categories), except: Tokens.capped(limitExceptions.domains))
        }
        return fitted.left
    }

    /// Shields apps and websites by token; `ShieldBudget` keeps all stores together within iOS's cap.
    private static func shieldOneByOne(_ split: Tokens.Split, in store: ManagedSettingsStore) {
        store.shield.applications = split.apps.isEmpty ? nil : split.apps
        store.shield.webDomains = split.domains.isEmpty ? nil : split.domains
    }

    /// Overflow stores (`limits.2` …) from before `ShieldBudget`: what they held counted against iOS's cap for all
    /// stores. Emptied once per phone; remove this once every kid phone's journal notes it.
    private static func clearRetiredStores(now: Date) {
        guard !FileManager.default.fileExists(atPath: AppGroup.retiredStoresClearedURL.path()) else { return }
        for name in ["restrictions", "downtime.some", "limits"] {
            for index in 2...6 {
                ManagedSettingsStore(named: .init("\(name).\(index)")).clearAllSettings()
            }
        }
        AppGroup.save(now, to: AppGroup.retiredStoresClearedURL)
        try? AppGroup.journal.append(.note("shields: cleared retired overflow stores"))
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

            /// Per shield setting (apps, websites, categories, or exceptions): with more, iOS shields nothing.
            static let limit = 50
        }

        static func capped<T>(_ tokens: Set<T>) -> Set<T> {
            Set(tokens.prefix(Split.limit))
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

        /// The app items holding `tokens`.
        func ids(of tokens: Set<ApplicationToken>) -> Set<UUID> {
            guard !tokens.isEmpty else { return [] }
            return Set(items.values.filter { $0.kind == .app && TokenCoding.application($0.tokenData).map(tokens.contains) == true }
                .map(\.id))
        }

        /// Categories replaced by their known apps and websites (for "all except" lists, which take apps only). Apple's
        /// data has no tokens, so those come from the scanned items matched to them; a scanned category finds its apps
        /// through its own match (`TokenPairing`). Unmatched apps can't be let through.
        func expandingCategories(_ ids: Set<UUID>) -> Set<UUID> {
            let categories = EnforcementPlanner.categoryNames(ids, items: items)
            guard !categories.isEmpty else { return ids }
            let members = Set(items.values.filter { $0.category.map(categories.contains) == true }.map(\.id))
            let scanned = items.values.filter { $0.match.map(members.contains) == true }.map(\.id)
            return ids.union(members).union(scanned)
        }
    }

    // MARK: - Activities

    /// One activity per Downtime interval (`dt.<id8>`, split `.a`/`.b` across midnight) and per limit but all-apps ones
    /// (`lim.<id8>`, one event `lim.<id8>.<budget>`). Re-registers only what changed: every registration replays
    /// passed thresholds.
    private static func registerActivities(policy: Policy, plan: EnforcementPlan, items: [UUID: TrackedItem], now: Date) {
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
            // An all-apps limit has no event: one over all activity would count Always Allowed and exempt apps too.
            // The wake alarm's wakes (every minute of use) reconcile it instead.
            // So has one whose categories hold an Always Allowed app, which its event would count.
            for limit in policy.limits where limit.enabled && !limit.allApps
                && !EnforcementPlanner.eventCountsAlwaysAllowed(limit, items: items, alwaysAllowed: policy.alwaysAllowed) {
                guard let budget = plan.budgets[limit.id] else { continue }
                let name = limitPrefix + short(limit.id)
                let targets = tokens.split(limit.items.subtracting(policy.alwaysAllowed))
                // An event with no tokens would count all activity.
                guard !targets.apps.isEmpty || !targets.categories.isEmpty || !targets.domains.isEmpty else { continue }
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
        if let ends = plan.extraMinuteEnds, let schedule = extraMinuteSchedule(ending: ends, now: now) {
            desired[extraMinuteActivity] = ("\(schedule.fire.timeIntervalSince1970)", { center in
                try center.startMonitoring(DeviceActivityName(extraMinuteActivity), during: schedule.schedule)
            })
        }
        let registered = AppGroup.load([String: String].self, from: AppGroup.enforcementActivitiesURL) ?? [:]
        let center = DeviceActivityCenter()
        let active = Set(center.activities.map(\.rawValue))
        let stale = registered.keys.filter { desired[$0] == nil } + active.filter { owns($0) && desired[$0] == nil }
        if !stale.isEmpty {  // never an empty list: that stops every activity
            center.stopMonitoring(Set(stale).map { DeviceActivityName($0) })
        }
        var now: [String: String] = [:]
        // The extra-minute alarm first: it is the one that must not be left out.
        let order = desired.sorted { ($0.key == extraMinuteActivity ? 0 : 1, $0.key) < ($1.key == extraMinuteActivity ? 0 : 1, $1.key) }
        for (name, entry) in order.prefix(maxActivities) {
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

    /// Schedules count whole minutes and last at least 15, so the alarm is an interval's end warning at the first whole
    /// minute after `ends` (up to a minute after the extra time runs out). Nil past 23:59: the new day's reconcile ends it.
    private static func extraMinuteSchedule(ending ends: Date, now: Date) -> (schedule: DeviceActivitySchedule, fire: Date)? {
        let calendar = Calendar.current
        func wholeMinute(_ date: Date, up: Bool) -> Date {
            let floor = calendar.dateInterval(of: .minute, for: date)?.start ?? date
            return up && floor < date ? floor.addingTimeInterval(60) : floor
        }
        let fire = wholeMinute(ends, up: true)
        let lastMinute = calendar.startOfDay(for: now).addingTimeInterval(Double(23 * 60 + 59) * 60)
        let end = min(wholeMinute(now, up: true).addingTimeInterval(16 * 60), lastMinute)
        guard fire < end else { return nil }
        let start = min(wholeMinute(now, up: false), end.addingTimeInterval(-15 * 60))
        func components(_ date: Date) -> DateComponents { calendar.dateComponents([.hour, .minute], from: date) }
        let warning = Int(end.timeIntervalSince(fire) / 60)
        let schedule = DeviceActivitySchedule(intervalStart: components(start), intervalEnd: components(end), repeats: false,
                                              warningTime: DateComponents(minute: warning))
        return (schedule, fire)
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
