import Foundation
import ManagedSettings
import ThymeCore

/// What the block page and its buttons know (PLAN.md §15.2), read from the App Group: the applied plan, the policy,
/// the kid's items and today's requests. Compiled into both shield extensions.
struct ShieldContext {
    let config = SharedConfig.load()
    let applied = AppGroup.load(AppliedPlan.self, from: AppGroup.enforcementURL)
    let policy = AppGroup.loadPolicy()
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
        return Target(item: nil, category: category, name: category?.displayName ?? "These apps")
    }

    func target(domainToken: WebDomainToken) -> Target {
        target(domain: WebDomain(token: domainToken))
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
        for limitID in plan.exhaustedLimits.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let limit = policy?.limits.first(where: { $0.id == limitID }) else { continue }
            if !limit.items.isDisjoint(with: ids) { return .limit(limitID) }
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
            return "You asked for \(Self.describe(minutes: request.minutes)). Open ScreenThyme to see your parent's answer."
        }
        if let answer = lastAnswer(for: target), !answer.approved {
            return "Your parent said no to more time for \(target.name) today."
        }
        switch reason {
        case let .downtime(windowID):
            guard let downtime = applied?.plan.downtime, downtime.windowID == windowID else { return "\(target.name) is off during Downtime." }
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

    // MARK: - Requests

    /// What a request from this page would ask for: Downtime off for the whole phone (a press on a category shield
    /// can't say which app), more time on a limit, or an exception for a blocked app or category. Nil: can't ask.
    func requestScope(for target: Target) -> (itemID: UUID?, reason: BlockReason)? {
        switch reason(for: target) {
        case let .downtime(id)?: (nil, .downtime(id))
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

    /// Queues a request for more time and an alert for the parents; `RequestSender` sends both at once.
    func request(_ target: Target, minutes: Int?) -> TimeRequest? {
        guard let kid = config.kid, let scope = requestScope(for: target) else { return nil }
        let request = TimeRequest(kidID: kid.id, itemID: scope.itemID, reason: scope.reason, minutes: minutes, at: Date())
        let amount = Self.describe(minutes: minutes).capitalizedFirst
        let body = switch scope.reason {
        case .downtime: "\(amount) of Downtime off, for the whole phone."
        case let .limit(id): "\(amount) on the \(applied?.limitNames[id] ?? "time") limit."
        case .blocked: "\(amount) of \(target.name), which isn't allowed."
        }
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
