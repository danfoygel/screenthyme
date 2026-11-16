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

    func pendingRequest(for target: Target) -> TimeRequest? {
        let answered = Set(state?.grants.map(\.grant.requestID) ?? [])
        let today = DayKey(Date())
        return AppGroup.requests.readAll().last { request in
            DayKey(request.at) == today && !answered.contains(request.id) && request.itemID == target.item?.id
        }
    }

    func lastAnswer(for target: Target) -> TimeGrant? {
        guard let item = target.item?.id else { return nil }
        return state?.grants.last { $0.grant.itemID == item }?.grant
    }

    /// Queues a request for more time and an alert for the parents (uploaded by the app or the next wake).
    func request(_ target: Target, minutes: Int?) -> TimeRequest? {
        guard let kid = config.kid else { return nil }
        let reason = reason(for: target) ?? .blocked
        let request = TimeRequest(kidID: kid.id, itemID: target.item?.id, reason: reason, minutes: minutes, at: Date())
        let why = switch reason {
        case .downtime: "during Downtime"
        case let .limit(id): "over the \(applied?.limitNames[id] ?? "time") limit"
        case .blocked: "though it's not allowed"
        }
        let alert = AlertRecord(kidID: kid.id, ruleID: nil, itemID: target.item?.id, at: request.at,
                                title: "\(kid.displayName) asks for more time",
                                body: "\(Self.describe(minutes: minutes).capitalizedFirst) of \(target.name), \(why).")
        do {
            try AppGroup.requests.append(contentsOf: [request])
            try AppGroup.outbox.append(contentsOf: [alert])
            try? AppGroup.journal.append(.note("asked for more time: \(target.name), \(Self.describe(minutes: minutes))"))
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
