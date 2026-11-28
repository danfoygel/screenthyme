import Foundation

/// One of a kid's rulesets (PLAN.md §15.15): the Downtime, App Limits and Blocked apps in effect on some days, like
/// school days, weekends or a trip. Exactly one is in effect on each day (`Policy.ruleSet(on:)`): the one a parent chose
/// for some days (`Policy.ruleSetChoice`), else the one for the weekday, else the first. Groups, custom categories,
/// Always Allowed, Uncounted, breaks, limit warnings and Content & Privacy are the same under every ruleset.
public struct PolicyRuleSet: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// The weekdays (Calendar numbering, 1 = Sunday) it's in effect by itself; empty: only when a parent chooses it.
    /// A weekday is in one ruleset at most.
    public var weekdays: Set<Int>
    public var downtime: [DowntimeWindow]
    public var limits: [AppLimit]
    public var blocked: Set<UUID>

    public init(id: UUID = UUID(), name: String, weekdays: Set<Int> = [], downtime: [DowntimeWindow] = [],
                limits: [AppLimit] = [], blocked: Set<UUID> = []) {
        self.id = id
        self.name = name
        self.weekdays = weekdays
        self.downtime = downtime
        self.limits = limits
        self.blocked = blocked
    }

    /// Rulesets saved before a field existed still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        weekdays = try container.decodeIfPresent(Set<Int>.self, forKey: .weekdays) ?? []
        downtime = try container.decodeIfPresent([DowntimeWindow].self, forKey: .downtime) ?? []
        limits = try container.decodeIfPresent([AppLimit].self, forKey: .limits) ?? []
        blocked = try container.decodeIfPresent(Set<UUID>.self, forKey: .blocked) ?? []
    }

    /// The same rules as a new ruleset: its windows and limits get new ids, so grants and limit fires stay with theirs.
    public func copy(id: UUID = UUID(), name: String, weekdays: Set<Int> = []) -> PolicyRuleSet {
        func newID(_ old: UUID) -> UUID { Replay.stableUUID("rule-set-item", id.uuidString, old.uuidString) }
        var copy = PolicyRuleSet(id: id, name: name, weekdays: weekdays, downtime: downtime, limits: limits,
                                 blocked: blocked)
        for index in copy.downtime.indices { copy.downtime[index].id = newID(downtime[index].id) }
        for index in copy.limits.indices { copy.limits[index].id = newID(limits[index].id) }
        return copy
    }

    /// "Mon–Fri", "Sat Sun", "Every day" or "Only when chosen".
    public func days(calendar: Calendar = .current) -> String {
        Self.days(weekdays, calendar: calendar)
    }

    public static func days(_ weekdays: Set<Int>, calendar: Calendar = .current) -> String {
        if weekdays.isEmpty { return "Only when chosen" }
        if weekdays.count == 7 { return "Every day" }
        if weekdays == [2, 3, 4, 5, 6] {
            return "\(calendar.shortWeekdaySymbols[1])–\(calendar.shortWeekdaySymbols[5])"
        }
        // Monday first, as a week reads.
        return weekdays.sorted { ($0 + 5) % 7 < ($1 + 5) % 7 }.map { calendar.shortWeekdaySymbols[$0 - 1] }
            .joined(separator: " ")
    }
}

/// A parent chose a ruleset for some days (PLAN.md §15.15): it's in effect on those days, whatever their weekday.
public struct RuleSetChoice: Codable, Sendable, Hashable {
    public var ruleSetID: UUID
    /// The ruleset's name when it was chosen, for the change history.
    public var name: String
    /// The midnight starting the day it was chosen.
    public var from: Date
    /// The midnight it ends, after the last day.
    public var until: Date
    public var at: Date
    /// The parent's name, as on their grants.
    public var by: String

    public init(ruleSet: PolicyRuleSet, days: Int, at now: Date, by parent: String, calendar: Calendar = .current) {
        ruleSetID = ruleSet.id
        name = ruleSet.name
        from = calendar.startOfDay(for: now)
        until = TemporaryChange.until(days: days, from: now, calendar: calendar)
        at = now
        by = parent
    }

    /// Whether it covers the day starting at midnight `day`.
    public func covers(_ day: Date) -> Bool { from <= day && day < until }

    /// The last day it covers (the day before `until`).
    public func lastDay(calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: -1, to: until)!
    }
}

extension Policy {
    /// The rulesets every kid starts with: Weekday (Monday to Friday), Weekend and Travel (only when chosen).
    public static let defaultRuleSets: [(name: String, weekdays: Set<Int>)] =
        [("Weekday", [2, 3, 4, 5, 6]), ("Weekend", [1, 7]), ("Travel", [])]

    /// A default ruleset's id: the same on every parent's phone, so two phones setting them up agree.
    public static func ruleSetID(kid: UUID, name: String) -> UUID {
        Replay.stableUUID("rule-set", kid.uuidString, name)
    }

    /// The policy with the default rulesets (`defaultRuleSets`), each holding the Downtime, limits and Blocked it had,
    /// so nothing changes until a parent edits one. Weekday keeps their ids; the others' copies get ids of their own.
    /// Temporary changes get them too, so they still change back. A policy with rulesets stays as it is.
    public func withDefaultRuleSets() -> Policy {
        guard ruleSets.isEmpty else { return self }
        var policy = self
        let rules = PolicyRuleSet(name: "", downtime: downtime, limits: limits, blocked: blocked)
        policy.ruleSets = Self.defaultRuleSets.enumerated().map { index, entry in
            let id = Self.ruleSetID(kid: kidID, name: entry.name)
            guard index > 0 else {
                var first = rules
                (first.id, first.name, first.weekdays) = (id, entry.name, entry.weekdays)
                return first
            }
            return rules.copy(id: id, name: entry.name, weekdays: entry.weekdays)
        }
        for index in policy.temporary.indices {
            policy.temporary[index].before = temporary[index].before.withDefaultRuleSets()
            policy.temporary[index].after = temporary[index].after.withDefaultRuleSets()
        }
        return policy
    }

    /// The ruleset with `id`.
    public func ruleSet(_ id: UUID) -> PolicyRuleSet? { ruleSets.first { $0.id == id } }

    /// The ruleset in effect on the day of `date`: the one chosen for it, else the one for its weekday, else the first.
    /// Nil for a policy without rulesets.
    public func ruleSet(on date: Date, calendar: Calendar = .current) -> PolicyRuleSet? {
        let day = calendar.startOfDay(for: date)
        if let choice = ruleSetChoice, choice.covers(day), let chosen = ruleSet(choice.ruleSetID) { return chosen }
        let weekday = calendar.component(.weekday, from: day)
        return ruleSets.first { $0.weekdays.contains(weekday) } ?? ruleSets.first
    }

    /// The choice in effect on the day of `date`, if a parent chose a ruleset for it.
    public func choice(on date: Date, calendar: Calendar = .current) -> RuleSetChoice? {
        guard let choice = ruleSetChoice, choice.covers(calendar.startOfDay(for: date)),
              ruleSet(choice.ruleSetID) != nil else { return nil }
        return choice
    }

    /// The policy with the Downtime, limits and Blocked of the ruleset in effect at `date`: what the planner, Enforcer,
    /// block page and screens read. Limits and Blocked are today's ruleset's. A Downtime window that started yesterday
    /// is yesterday's ruleset's (a Friday's bedtime runs into Saturday morning), one that starts today today's, so on a
    /// day the ruleset changes each window is kept to the one day it starts. A choice that covers neither day is
    /// dropped. A policy without rulesets stays as it is.
    func applyingRuleSet(at date: Date, calendar: Calendar = .current) -> Policy {
        guard let current = ruleSet(on: date, calendar: calendar) else { return self }
        let today = calendar.startOfDay(for: date)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let previous = ruleSet(on: yesterday, calendar: calendar) ?? current
        var policy = self
        policy.limits = current.limits
        policy.blocked = current.blocked
        if previous.id == current.id {
            policy.downtime = current.downtime
        } else {
            func starting(on day: Date, _ windows: [DowntimeWindow]) -> [DowntimeWindow] {
                let weekday = calendar.component(.weekday, from: day)
                return windows.filter { $0.weekdays.isEmpty || $0.weekdays.contains(weekday) }.map { window in
                    var window = window
                    window.weekdays = [weekday]
                    return window
                }
            }
            var windows = starting(on: yesterday, previous.downtime.filter(\.daily.wraps))
            for window in starting(on: today, current.downtime) {
                if let index = windows.firstIndex(where: { $0.id == window.id }) {
                    windows[index].weekdays.formUnion(window.weekdays)
                } else {
                    windows.append(window)
                }
            }
            policy.downtime = windows
        }
        if let choice = ruleSetChoice, choice.until <= yesterday || ruleSet(choice.ruleSetID) == nil {
            policy.ruleSetChoice = nil
        }
        return policy
    }

    /// The policy to save at `now`: in force then (`current(at:)`), but with the Downtime, limits and Blocked of the
    /// ruleset in effect as they are, not kept to today. A kid's phone on a build from before rulesets enforces those
    /// every day.
    public func saving(at now: Date, calendar: Calendar = .current) -> Policy {
        var policy = current(at: now, calendar: calendar)
        if let set = policy.ruleSet(on: now, calendar: calendar) {
            (policy.downtime, policy.limits, policy.blocked) = (set.downtime, set.limits, set.blocked)
        }
        return policy
    }

    /// Changes the ruleset with `id`, if there is one.
    public mutating func editRuleSet(_ id: UUID, _ change: (inout PolicyRuleSet) -> Void) {
        guard let index = ruleSets.firstIndex(where: { $0.id == id }) else { return }
        change(&ruleSets[index])
    }

    /// Adds `ruleSet` or replaces the one with its id. Its weekdays leave every other ruleset: a day has one.
    public mutating func save(_ ruleSet: PolicyRuleSet) {
        for index in ruleSets.indices where ruleSets[index].id != ruleSet.id {
            ruleSets[index].weekdays.subtract(ruleSet.weekdays)
        }
        if let index = ruleSets.firstIndex(where: { $0.id == ruleSet.id }) {
            ruleSets[index] = ruleSet
        } else {
            ruleSets.append(ruleSet)
        }
    }

    /// Removes a ruleset, and a choice of it; the last one stays. Its weekdays then have the first ruleset's rules.
    public mutating func removeRuleSet(_ id: UUID) {
        guard ruleSets.count > 1 else { return }
        ruleSets.removeAll { $0.id == id }
        if ruleSetChoice?.ruleSetID == id { ruleSetChoice = nil }
    }

    /// The weekdays no ruleset has: they get the first one's rules.
    public var unscheduledWeekdays: Set<Int> {
        guard !ruleSets.isEmpty else { return [] }
        return Set(1...7).subtracting(ruleSets.flatMap(\.weekdays))
    }

    /// Changes Downtime, limits and Blocked everywhere they are: the policy's own and every ruleset's.
    mutating func editAllRules(_ change: (inout [DowntimeWindow], inout [AppLimit], inout Set<UUID>) -> Void) {
        change(&downtime, &limits, &blocked)
        for index in ruleSets.indices {
            var set = ruleSets[index]
            change(&set.downtime, &set.limits, &set.blocked)
            ruleSets[index] = set
        }
    }
}

extension RuleSetChoice {
    /// "Today only" (on the day it was chosen) or "Through Sunday 30 November".
    public func span(calendar: Calendar = .current) -> String {
        let last = lastDay(calendar: calendar)
        if last == from { return "Today only" }
        let format = DateFormatter()
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return "Through \(format.string(from: last))"
    }
}
