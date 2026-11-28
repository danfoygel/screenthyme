import Foundation

/// A parent's save made for some days only (PLAN.md §15.10): the policy before and after it, and when it changes back.
/// Kept in the policy it changed (`Policy.temporary`), so the kid's phone changes back by itself, offline too, at its
/// first wake after `until`, which is a midnight (the wake alarm restarts then). Only what the save changed goes back,
/// and only where no later save changed it again (`Policy.reverting`).
public struct TemporaryChange: Codable, Sendable, Hashable, Identifiable {
    /// The `PolicyChange` that made it.
    public var id: UUID
    public var until: Date
    /// Both without temporary changes of their own. With rulesets after, `before` has them too: changing back must not
    /// take them away.
    public var before: Policy
    public var after: Policy

    public init(id: UUID, until: Date, before: Policy, after: Policy) {
        self.id = id
        self.until = until
        self.before = after.ruleSets.isEmpty ? before : before.withDefaultRuleSets()
        self.after = after
        self.before.temporary = []
        self.after.temporary = []
    }

    /// The midnight that ends a change for `days` days: 1 is the rest of today.
    public static func until(days: Int, from now: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: max(days, 1), to: calendar.startOfDay(for: now))!
    }
}

/// One temporary change changing back, with the policy just before and after.
public struct PolicyRevertStep: Sendable, Hashable {
    public var change: TemporaryChange
    public var before: Policy
    public var after: Policy

    public var edits: [PolicyEdit] { PolicyEdit.between(before, after) }
}

extension Policy {
    /// The policy in force at `date`: the temporary changes that ended by then changed back, and dropped, with the
    /// Downtime, limits and Blocked of the ruleset in effect then (`applyingRuleSet`).
    public func current(at date: Date, calendar: Calendar = .current) -> Policy {
        let reverted = temporary.contains(where: { $0.until <= date }) ? reverts(through: date).last!.after : self
        return reverted.applyingRuleSet(at: date, calendar: calendar)
    }

    /// Each temporary change that ends by `date`, in the order they change back: earliest end first, and of those
    /// ending together the one saved last first, so stacked changes unwind.
    public func reverts(through date: Date) -> [PolicyRevertStep] {
        let due = temporary.enumerated().filter { $0.element.until <= date }
            .sorted { ($0.element.until, -$0.offset) < ($1.element.until, -$1.offset) }.map(\.element)
        var policy = self
        return due.map { change in
            let before = policy
            policy = policy.reverting(change)
            policy.temporary.removeAll { $0.id == change.id }
            return PolicyRevertStep(change: change, before: before, after: policy)
        }
    }

    /// Drops temporary changes that would change nothing back: everything they changed was changed again since.
    public mutating func dropSpentTemporaryChanges() {
        let spent = Set(reverts(through: .distantFuture).filter(\.edits.isEmpty).map(\.change.id))
        temporary.removeAll { spent.contains($0.id) }
    }

    /// The policy with `change` undone where it still holds: what it added goes, what it removed comes back and what it
    /// changed goes back, field by field. What a later save changed again stays. `temporary` is left as it is.
    public func reverting(_ change: TemporaryChange) -> Policy {
        let (old, new) = (change.before, change.after)
        var policy = self
        revertValue(&policy, \.enabled, old, new)
        policy.downtime = revertElements(downtime, old.downtime, new.downtime, fields: revertWindow)
        policy.limits = revertElements(limits, old.limits, new.limits, fields: revertLimit)
        revertSet(&policy.blocked, old.blocked, new.blocked)
        policy.ruleSets = revertElements(ruleSets, old.ruleSets, new.ruleSets) { set, old, new in
            revertValue(&set, \.name, old, new)
            revertValue(&set, \.weekdays, old, new)
            set.downtime = revertElements(set.downtime, old.downtime, new.downtime, fields: revertWindow)
            set.limits = revertElements(set.limits, old.limits, new.limits, fields: revertLimit)
            revertSet(&set.blocked, old.blocked, new.blocked)
            revertValue(&set, \.limitWarningPercents, old, new)
        }
        policy.groups = revertElements(groups, old.groups, new.groups) { group, old, new in
            revertValue(&group, \.name, old, new)
            revertSet(&group.items, old.items, new.items)
            revertSet(&group.moved, old.moved, new.moved)
        }
        revertSet(&policy.alwaysAllowed, old.alwaysAllowed, new.alwaysAllowed)
        // What Always Allowed no longer holds can't come back as Uncounted.
        revertSet(&policy.uncounted, old.uncounted, new.uncounted)
        policy.uncounted.formIntersection(policy.alwaysAllowed)
        revertValue(&policy, \.breaks, old, new)
        revertValue(&policy, \.limitWarningPercents, old, new)
        for field in Restrictions.fields { field(&policy.restrictions, old.restrictions, new.restrictions) }
        return policy
    }
}

extension Restrictions {
    /// Each setting, changed back from `new` to `old` where it still is `new`.
    static var fields: [(inout Restrictions, Restrictions, Restrictions) -> Void] {
        func field<V: Equatable>(_ keyPath: WritableKeyPath<Restrictions, V>) -> (inout Restrictions, Restrictions, Restrictions) -> Void {
            { value, old, new in revertValue(&value, keyPath, old, new) }
        }
        return [
            field(\.denyAppInstallation), field(\.denyAppRemoval), field(\.denyInAppPurchases),
            field(\.requirePasswordForPurchases), field(\.maximumAppRating), field(\.denyExplicitContent),
            field(\.maximumMovieRating), field(\.maximumTVShowRating), field(\.denyBookstoreErotica),
            field(\.denyMusicService), field(\.webFilter), field(\.denySiri), field(\.denyMultiplayerGaming),
            field(\.denyAddingFriends), field(\.lockAccounts), field(\.lockPasscode), field(\.lockAppCellularData),
            field(\.lockCellularPlan), field(\.lockESIM), field(\.requireAutomaticDateAndTime),
            field(\.denySafariAutoFill),
        ]
    }
}

private func revertWindow(_ window: inout DowntimeWindow, _ old: DowntimeWindow, _ new: DowntimeWindow) {
    revertValue(&window, \.name, old, new)
    revertValue(&window, \.startMinute, old, new)
    revertValue(&window, \.endMinute, old, new)
    revertValue(&window, \.weekdays, old, new)
    revertSet(&window.items, old.items, new.items)
}

private func revertLimit(_ limit: inout AppLimit, _ old: AppLimit, _ new: AppLimit) {
    revertValue(&limit, \.name, old, new)
    revertValue(&limit, \.allApps, old, new)
    revertValue(&limit, \.minutes, old, new)
    revertValue(&limit, \.weekdayMinutes, old, new)
    revertValue(&limit, \.enabled, old, new)
    revertSet(&limit.items, old.items, new.items)
}

private func revertValue<T, V: Equatable>(_ value: inout T, _ keyPath: WritableKeyPath<T, V>, _ old: T, _ new: T) {
    if value[keyPath: keyPath] == new[keyPath: keyPath] { value[keyPath: keyPath] = old[keyPath: keyPath] }
}

/// Members the change added go (if still there); members it removed come back.
private func revertSet<E>(_ set: inout Set<E>, _ old: Set<E>, _ new: Set<E>) {
    set.subtract(new.subtracting(old))
    set.formUnion(old.subtracting(new))
}

/// Windows, limits or groups by id: one the change added goes unless changed since, one it removed comes back where it
/// was unless added again since, and one it changed goes back field by field (`fields`). One deleted since stays
/// deleted.
private func revertElements<T: Identifiable & Equatable>(_ current: [T], _ old: [T], _ new: [T],
                                                       fields: (inout T, T, T) -> Void) -> [T] {
    let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let newByID = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var result: [T] = current.compactMap { value in
        guard let changed = newByID[value.id] else { return value }
        guard let previous = oldByID[value.id] else { return value == changed ? nil : value }
        var value = value
        fields(&value, previous, changed)
        return value
    }
    for (index, value) in old.enumerated() where newByID[value.id] == nil && !result.contains(where: { $0.id == value.id }) {
        result.insert(value, at: min(index, result.count))
    }
    return result
}

/// A temporary save's change back, in a kid's change history: past, or still to come.
public struct PolicyRevert: Sendable, Hashable, Identifiable {
    /// The temporary save.
    public var change: PolicyChange
    public var at: Date
    public var edits: [PolicyEdit]

    public var id: UUID { Replay.stableUUID("policy-revert", change.id.uuidString) }

    /// Each temporary save's change back, worked out from the policy saved last before it ends (`current` for one
    /// still to come), as the kid's phone does it. None for one that a later save left nothing to change back.
    public static func all(changes: [PolicyChange], current: Policy?) -> [PolicyRevert] {
        let sorted = changes.sorted { $0.at < $1.at }
        return sorted.compactMap { change in
            guard let until = change.until else { return nil }
            let saved = current.flatMap { $0.updatedAt < until ? $0 : nil } ?? sorted.last(where: { $0.at < until })?.after
            guard let step = saved?.reverts(through: until).first(where: { $0.change.id == change.id }) else { return nil }
            let edits = step.edits
            return edits.isEmpty ? nil : PolicyRevert(change: change, at: until, edits: edits)
        }
    }
}
