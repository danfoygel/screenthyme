import Foundation
import ManagedSettings
import ThymeCore

/// What the block page and its buttons know (PLAN.md §15.2), read from the App Group: the applied plan, the policy,
/// the kid's items and today's requests. Compiled into both shield extensions.
struct ShieldContext {
    let config = SharedConfig.load()
    let applied = AppGroup.load(AppliedPlan.self, from: AppGroup.enforcementURL)
    /// Groups resolved to their items (`Policy.resolved`).
    let policy = AppGroup.loadPolicy()?.resolved
    let items = AppGroup.loadItems()
    let state = AppGroup.load(EnforcementDayState.self, from: AppGroup.enforcementStateURL)

    /// A blocked app, website or category as the shield names it.
    struct Target {
        var item: TrackedItem?
        var category: TrackedItem?
        var name: String
    }

    func target(app: Application, category: ActivityCategory? = nil) -> Target {
        let item = items.first { candidate in
            guard candidate.kind == .app else { return false }
            // Scanned items have only a token; Apple's data items only a bundle ID.
            if let token = app.token, TokenCoding.application(candidate.tokenData) == token { return true }
            return app.bundleIdentifier.map { candidate.identifier == $0 } ?? false
        }
        return Target(item: item, category: categoryItem(category, name: item?.category),
                      name: app.localizedDisplayName ?? item?.displayName ?? "This app")
    }

    func target(domain: WebDomain, category: ActivityCategory? = nil) -> Target {
        let item = items.first { candidate in
            guard candidate.kind == .domain else { return false }
            if let token = domain.token, TokenCoding.webDomain(candidate.tokenData) == token { return true }
            return domain.domain.map { candidate.identifier == $0 } ?? false
        }
        return Target(item: item, category: categoryItem(category, name: item?.category),
                      name: domain.domain ?? item?.displayName ?? "This website")
    }

    func target(appToken: ApplicationToken) -> Target {
        target(app: Application(token: appToken))
    }

    /// A press on a category shield (Downtime, category limits) names only the category.
    func target(categoryToken: ActivityCategoryToken) -> Target {
        let category = items.first { $0.kind == .category && TokenCoding.category($0.tokenData) == categoryToken }
        return Target(item: nil, category: category, name: category.map(name(of:)) ?? "These apps")
    }

    /// A scanned category goes by its match's name, from Apple's data (`TokenPairing`).
    func name(of category: TrackedItem) -> String {
        if category.nickname == nil, let match = category.match, let named = items.first(where: { $0.id == match }) {
            return named.displayName
        }
        return category.displayName
    }

    func target(domainToken: WebDomainToken) -> Target {
        target(domain: WebDomain(token: domainToken))
    }

    /// What a button press on this page will name: a page shown through a category shield passes the category to the
    /// action extension, not the app.
    func pressed(_ target: Target, inCategory: Bool) -> Target {
        guard inCategory else { return target }
        return Target(item: nil, category: target.category, name: target.category.map(name(of:)) ?? "These apps")
    }

    private func categoryItem(_ category: ActivityCategory?, name: String?) -> TrackedItem? {
        items.first { candidate in
            guard candidate.kind == .category else { return false }
            if let token = category?.token, TokenCoding.category(candidate.tokenData) == token { return true }
            return candidate.identifier == (category?.localizedDisplayName ?? name)
        }
    }

    /// Why `target` is blocked, by the plan: Downtime first, then limits, then always blocked.
    func reason(for target: Target) -> BlockReason? {
        guard let plan = applied?.plan else { return nil }
        let ids = Set([target.item?.id, target.category?.id].compactMap { $0 })
        if let downtime = plan.downtime, ids.isDisjoint(with: plan.downtimeExceptions) { return .downtime(downtime.windowID) }
        for downtime in plan.scopedDowntime where !downtime.items.isDisjoint(with: ids) && downtime.exceptions.isDisjoint(with: ids) {
            return .downtime(downtime.windowID)
        }
        // A limit on the app itself first, then all-apps limits.
        let exhausted = (policy?.limits ?? []).filter { plan.exhaustedLimits.contains($0.id) }
            .sorted { ($0.allApps ? 1 : 0, $0.id.uuidString) < ($1.allApps ? 1 : 0, $1.id.uuidString) }
        for limit in exhausted where (limit.allApps ? plan.allAppsLimited : !limit.items.isDisjoint(with: ids))
            && (plan.limitPasses[limit.id] ?? []).isDisjoint(with: ids) {
            return .limit(limit.id)
        }
        if !plan.blockedItems.isDisjoint(with: ids) { return .blocked }
        // Shielded but unexplained (the plan changed since): most likely Downtime or a limit just ended.
        return plan.exhaustedLimits.first.map { .limit($0) }
    }

    func title(for reason: BlockReason?) -> String {
        switch reason {
        case .downtime: "Downtime"
        case .limit: "Time limit"
        case .blocked: "Not allowed"
        case nil: "Blocked"
        }
    }

    func subtitle(for target: Target, reason: BlockReason?) -> String {
        if let request = pendingRequest(for: target) {
            return "You asked for \(Self.describe(minutes: request.minutes)). Tap Ask for more time to see the answer."
        }
        if let answer = lastAnswer(for: target), !answer.approved {
            return "Your parent said no to more time for \(target.name) today."
        }
        switch reason {
        case let .downtime(windowID):
            guard let downtime = applied?.plan.downtime(windowID) else { return "\(target.name) is off during Downtime." }
            return "\(target.name) is off until \(downtime.interval.end.formatted(date: .omitted, time: .shortened))."
        case let .limit(limitID):
            let name = applied?.limitNames[limitID] ?? target.name
            let budget = applied?.plan.budgets[limitID].map { " (\(Self.describe(minutes: $0)))" } ?? ""
            return "You've reached today's limit for \(name)\(budget)."
        case .blocked:
            return "Your parents don't allow \(target.name)."
        case nil:
            return "\(target.name) is blocked by ScreenThyme."
        }
    }

    // MARK: - More time

    /// "Ask for more time" opens this menu (iOS 26.4 submenu items), or with no choice to make asks straight away.
    enum MoreTime {
        case oneMoreMinute
        case ask

        /// `minutes`: the kid phone's choice for one more minute (`SharedConfig.extraMinuteLength`).
        func title(minutes: Int) -> String {
            switch self {
            case .oneMoreMinute: minutes == 1 ? "One more minute" : "\(minutes) more minutes"
            case .ask: "Ask a parent"
            }
        }
    }

    /// The menu for a press on `target` (see `pressed`). The page and the action extension compute it alike, so the
    /// item pressed maps back to the same choice.
    func moreTimeMenu(for target: Target) -> [MoreTime] {
        extraMinuteScope(for: target) == nil ? [] : [.oneMoreMinute, .ask]
    }

    /// What one more minute would let through: as a request would ask (`requestScope`), if today's minute for it is
    /// unused. Never for apps that aren't allowed.
    func extraMinuteScope(for target: Target) -> (itemID: UUID?, reason: BlockReason)? {
        guard let scope = requestScope(for: target) else { return nil }
        let today = state.flatMap { $0.day == DayKey(Date()) ? $0 : nil } ?? EnforcementDayState(day: DayKey(Date()))
        return today.canTakeExtraMinute(itemID: scope.itemID, reason: scope.reason) ? scope : nil
    }

    // MARK: - Requests

    /// What a request for `target` asks for: Downtime off for that app (or the whole phone, with no app), more time on
    /// a limit, or an exception for a blocked app or category. Nil: nothing to ask for. An all-apps limit's shield
    /// names only a category, which says nothing: like Downtime, its press is for the whole phone. Downtime for some
    /// apps shields their categories by name, so its press is for the category.
    func requestScope(for target: Target) -> (itemID: UUID?, reason: BlockReason)? {
        switch reason(for: target) {
        case let .downtime(id)? where applied?.plan.downtime?.windowID != id: (target.item?.id ?? target.category?.id, .downtime(id))
        case let .downtime(id)?: (target.item?.id, .downtime(id))
        case let .limit(id)? where policy?.limits.first(where: { $0.id == id })?.allApps == true: (target.item?.id, .limit(id))
        case let .limit(id)?: (target.item?.id ?? target.category?.id, .limit(id))
        case .blocked?: (target.item?.id ?? target.category?.id).map { ($0, .blocked) }
        case nil: nil
        }
    }

    /// Today's unanswered request this page's request would repeat.
    func pendingRequest(for target: Target) -> TimeRequest? {
        guard let scope = requestScope(for: target) else { return nil }
        let answered = Set(state?.grants.map(\.grant.requestID) ?? [])
        let today = DayKey(Date())
        return AppGroup.requests.readAll().last { request in
            DayKey(request.at) == today && !answered.contains(request.id) && request.reason == scope.reason
                && (scope.itemID == nil || request.itemID == scope.itemID)
        }
    }

    func lastAnswer(for target: Target) -> TimeGrant? {
        guard let scope = requestScope(for: target) else { return nil }
        return state?.grants.last { $0.grant.reason == scope.reason && $0.grant.itemID == scope.itemID }?.grant
    }

    /// Queues a request for more time and an alert for the parents, for the app to upload.
    func request(_ target: Target, minutes: Int?, note: String? = nil) -> TimeRequest? {
        guard let kid = config.kid, let scope = requestScope(for: target) else { return nil }
        let request = TimeRequest(kidID: kid.id, itemID: scope.itemID, reason: scope.reason, minutes: minutes, at: Date(),
                                  note: note)
        let amount = Self.describe(minutes: minutes).capitalizedFirst
        var body = switch scope.reason {
        case .downtime: scope.itemID == nil ? "\(amount) of Downtime off, for the whole phone." : "\(amount) during Downtime."
        case let .limit(id): "\(amount) on the \(applied?.limitNames[id] ?? "time") limit."
        case .blocked: "\(amount), though it isn't allowed."
        }
        if let note { body += " \u{201C}\(note)\u{201D}" }
        let alert = AlertRecord(kidID: kid.id, ruleID: nil, itemID: scope.itemID, at: request.at,
                                title: "\(kid.displayName) asks for more time", body: body)
        do {
            try AppGroup.requests.append(contentsOf: [request])
            try AppGroup.outbox.append(contentsOf: [alert])
            try? AppGroup.journal.append(.note("asked for more time: \(body)"))
        } catch {
            try? AppGroup.journal.append(.note("request failed: \(error)"))
        }
        return request
    }

    /// The block page's "Ask for more time": what was blocked, written by the button's extension for ScreenThyme,
    /// which it opens next (the configuration extension can't write the App Group).
    struct Ask: Codable {
        var itemID: UUID?
        var categoryID: UUID?
        var at: Date

        static var url: URL { AppGroup.container.appending(path: "ask.json") }

        func save() {
            AppGroup.save(self, to: Self.url)
        }

        /// The ask from the last minute, once.
        static func take(now: Date = Date()) -> Ask? {
            defer { try? FileManager.default.removeItem(at: url) }
            guard let ask = AppGroup.load(Ask.self, from: url), now.timeIntervalSince(ask.at) < 60 else { return nil }
            return ask
        }
    }

    func target(_ ask: Ask) -> Target {
        let item = items.first { $0.id == ask.itemID }
        let category = items.first { $0.id == ask.categoryID }
        return Target(item: item, category: category, name: item?.displayName ?? category.map(name(of:)) ?? "This app")
    }

    func target(item: TrackedItem) -> Target {
        Target(item: item, category: categoryItem(nil, name: item.category), name: item.displayName)
    }

    static let requestChoices: [Int?] = [15, 60, nil]

    static func describe(minutes: Int?) -> String {
        switch minutes {
        case nil: "the rest of today"
        case 60?: "1 more hour"
        case let minutes?: "\(minutes) more minutes"
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
