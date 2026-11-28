import Foundation

/// A notification on the kid's phone that a limit is running out: a share of today's budget is used (PLAN.md §15.2).
public struct LimitWarning: Codable, Sendable, Hashable {
    /// The last warning a limit gave today, at the budget it had then: a grant or a parent's change to the budget
    /// lets its warnings come again.
    public struct Sent: Codable, Sendable, Hashable {
        public var percent: Int
        public var budget: Int
    }

    public var limitID: UUID
    public var name: String
    public var percent: Int
    /// Minutes used today and today's budget, as the plan counts them.
    public var used: Int
    public var budget: Int

    public var left: Int { max(budget - used, 0) }

    public var title: String { "\(PolicyEdit.minutes(left)) left: \(name)" }

    public var body: String {
        "You've used \(PolicyEdit.minutes(used)) of today's \(PolicyEdit.minutes(budget)) (\(percent)%)."
    }

    /// The warnings `plan` calls for that `sent` hasn't given: for each limit not yet used up, the highest of
    /// `percents` that today's use has reached, if higher than the last one sent at the same budget. Updates `sent`.
    public static func due(in plan: EnforcementPlan, limits: [AppLimit], percents: [Int], sent: inout [UUID: Sent])
        -> [LimitWarning] {
        var due: [LimitWarning] = []
        for limit in limits where limit.enabled {
            guard let budget = plan.budgets[limit.id], budget > 0, let used = plan.used[limit.id],
                  !plan.exhaustedLimits.contains(limit.id),
                  let percent = percents.filter({ (1...99).contains($0) && used * 100 >= $0 * budget }).max()
            else { continue }
            if let last = sent[limit.id], last.budget == budget, last.percent >= percent { continue }
            sent[limit.id] = Sent(percent: percent, budget: budget)
            due.append(LimitWarning(limitID: limit.id, name: limit.name, percent: percent, used: used, budget: budget))
        }
        return due
    }
}

extension Policy {
    /// Limits warn the kid before they run out, and there's a limit to warn about in some ruleset: the kid's phone then
    /// asks to post notifications.
    public var hasLimitWarnings: Bool {
        !limitWarningPercents.isEmpty && (limits + ruleSets.flatMap(\.limits)).contains(where: \.enabled)
    }

    /// The next warning to add: 75%, 90% and 50% first, then the lowest free one; nil when every 5% is set.
    public var nextLimitWarning: Int? {
        let taken = Set(limitWarningPercents)
        return ([75, 90, 50] + Array(stride(from: 5, through: 95, by: 5))).first { !taken.contains($0) }
    }

    /// Warning `index` stepped 5% up or down, past the percentages already set; nil past 5–95%.
    public func steppingLimitWarning(_ index: Int, up: Bool) -> Int? {
        guard limitWarningPercents.indices.contains(index) else { return nil }
        let taken = Set(limitWarningPercents)
        return sequence(first: limitWarningPercents[index]) { $0 + (up ? 5 : -5) }.dropFirst()
            .prefix { (5...95).contains($0) }.first { !taken.contains($0) }
    }
}
