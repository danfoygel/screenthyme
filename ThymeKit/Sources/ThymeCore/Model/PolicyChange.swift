import Foundation

/// One parent's save of a kid's policy, for the change history (PLAN.md §15.7): who, when, and the policy before and
/// after, so the history can say what changed in names as they are now. Saved as `PolicyChange.<id>`; only parents'
/// phones read them.
public struct PolicyChange: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kidID: UUID
    public var at: Date
    /// The parent's name, as on their grants (`AppModel.senderName`).
    public var by: String
    /// `nil` for the kid's first policy, which was edited from an empty one.
    public var before: Policy?
    public var after: Policy
    /// A save for some days only: when it changes back (its `TemporaryChange` in `after.temporary`, same id).
    public var until: Date?

    public init(id: UUID = UUID(), kidID: UUID, at: Date, by: String, before: Policy?, after: Policy, until: Date? = nil) {
        self.id = id
        self.kidID = kidID
        self.at = at
        self.by = by
        self.before = before
        self.after = after
        self.until = until
    }

    public var edits: [PolicyEdit] {
        PolicyEdit.between(before ?? Policy(kidID: kidID), after)
    }

    /// The policy in force at `date`: the last save before it, or the first save's `before` (nil when the kid had none
    /// yet). `current` when nothing was saved since `date`, or no saves are known. Temporary changes that ended by
    /// `date` are changed back.
    public static func policy(at date: Date, changes: [PolicyChange], current: Policy?) -> Policy? {
        let sorted = changes.sorted { $0.at < $1.at }
        guard let next = sorted.first(where: { $0.at > date }) else { return current?.current(at: date) }
        return (sorted.last { $0.at <= date }?.after ?? next.before)?.current(at: date)
    }
}

/// One difference between two policies. Items stay ids, named when shown.
public enum PolicyEdit: Sendable, Hashable {
    case enforcement(on: Bool)
    case downtimeAdded(DowntimeWindow)
    case downtimeRemoved(DowntimeWindow)
    case downtimeChanged(from: DowntimeWindow, to: DowntimeWindow)
    case limitAdded(AppLimit)
    case limitRemoved(AppLimit)
    case limitChanged(from: AppLimit, to: AppLimit)
    case groupAdded(ItemGroup)
    case groupRemoved(ItemGroup)
    case groupChanged(from: ItemGroup, to: ItemGroup)
    /// Custom categories set up for Apple's (`Policy.withCustomCategories`), by name.
    case categoriesAdded([String])
    /// An app or website moved between custom categories (PLAN.md §15.14): the groups it left and joined, nil for the
    /// one of Apple's own category for it.
    case categoryMove(item: UUID, from: UUID?, to: UUID?)
    case alwaysAllowed(added: Set<UUID>, removed: Set<UUID>)
    case uncounted(added: Set<UUID>, removed: Set<UUID>)
    case blocked(added: Set<UUID>, removed: Set<UUID>)
    /// A Content & Privacy setting, with its values as shown ("On", "12+").
    case restriction(name: String, from: String, to: String)
    case websites(list: String, added: [String], removed: [String])
    case breaks(from: BreakRule?, to: BreakRule?)
    /// The default rulesets set up (`Policy.withDefaultRuleSets`), by name.
    case ruleSetsSetUp([String])
    case ruleSetAdded(PolicyRuleSet)
    case ruleSetRemoved(PolicyRuleSet)
    /// A ruleset renamed, or its weekdays changed. Changes to its rules are `inRuleSet`.
    case ruleSetChanged(from: PolicyRuleSet, to: PolicyRuleSet)
    /// A change to one ruleset's Downtime, limits or Blocked, with the ruleset's name.
    indirect case inRuleSet(String, PolicyEdit)
    /// A parent chose a ruleset for some days; nil: back to each weekday's own.
    case ruleSetChosen(RuleSetChoice?)

    /// In the order the policy screen shows them.
    public static func between(_ old: Policy, _ new: Policy) -> [PolicyEdit] {
        var edits: [PolicyEdit] = []
        if old.enabled != new.enabled { edits.append(.enforcement(on: new.enabled)) }
        if new.ruleSets.isEmpty {
            edits += ruleChanges(old.downtime, old.limits, old.blocked, new.downtime, new.limits, new.blocked)
        } else {
            // With rulesets, the policy's own Downtime, limits and Blocked are only the ruleset in effect's.
            var old = old
            if old.ruleSets.isEmpty {
                old = old.withDefaultRuleSets()
                edits.append(.ruleSetsSetUp(old.ruleSets.map(\.name)))
            }
            if old.ruleSetChoice != new.ruleSetChoice { edits.append(.ruleSetChosen(new.ruleSetChoice)) }
            edits += changes(old.ruleSets, new.ruleSets, added: PolicyEdit.ruleSetAdded, removed: PolicyEdit.ruleSetRemoved,
                             changed: { $0.name == $1.name && $0.weekdays == $1.weekdays ? nil : .ruleSetChanged(from: $0, to: $1) })
            for set in new.ruleSets {
                let previous = old.ruleSet(set.id) ?? PolicyRuleSet(id: set.id, name: set.name)
                edits += ruleChanges(previous.downtime, previous.limits, previous.blocked, set.downtime, set.limits,
                                     set.blocked).map { .inRuleSet(set.name, $0) }
            }
        }
        edits += changes(old.groups.filter { !$0.isCategory }, new.groups.filter { !$0.isCategory },
                         added: PolicyEdit.groupAdded, removed: PolicyEdit.groupRemoved, changed: PolicyEdit.groupChanged)
        edits += categoryChanges(old.groups.filter(\.isCategory), new.groups.filter(\.isCategory))
        if (old.breaks?.enabled == true ? old.breaks : nil) != (new.breaks?.enabled == true ? new.breaks : nil) {
            edits.append(.breaks(from: old.breaks, to: new.breaks))
        }
        if old.alwaysAllowed != new.alwaysAllowed {
            edits.append(.alwaysAllowed(added: new.alwaysAllowed.subtracting(old.alwaysAllowed),
                                        removed: old.alwaysAllowed.subtracting(new.alwaysAllowed)))
        }
        if old.uncounted != new.uncounted {
            edits.append(.uncounted(added: new.uncounted.subtracting(old.uncounted),
                                    removed: old.uncounted.subtracting(new.uncounted)))
        }
        for setting in Restrictions.settings {
            let (from, to) = (setting.value(old.restrictions), setting.value(new.restrictions))
            if from != to { edits.append(.restriction(name: setting.name, from: from, to: to)) }
        }
        let (oldLists, newLists) = (old.restrictions.webFilter.lists, new.restrictions.webFilter.lists)
        for list in WebFilter.listNames {
            let (from, to) = (oldLists[list] ?? [], newLists[list] ?? [])
            let added = to.filter { !from.contains($0) }, removed = from.filter { !to.contains($0) }
            if !added.isEmpty || !removed.isEmpty { edits.append(.websites(list: list, added: added, removed: removed)) }
        }
        return edits
    }

    /// Downtime, limits and Blocked: the policy's own, or a ruleset's.
    private static func ruleChanges(_ oldDowntime: [DowntimeWindow], _ oldLimits: [AppLimit], _ oldBlocked: Set<UUID>,
                                    _ downtime: [DowntimeWindow], _ limits: [AppLimit], _ blocked: Set<UUID>) -> [PolicyEdit] {
        var edits = changes(oldDowntime, downtime, added: PolicyEdit.downtimeAdded, removed: PolicyEdit.downtimeRemoved,
                            changed: PolicyEdit.downtimeChanged)
        edits += changes(oldLimits, limits, added: PolicyEdit.limitAdded, removed: PolicyEdit.limitRemoved,
                         changed: PolicyEdit.limitChanged)
        if oldBlocked != blocked {
            edits.append(.blocked(added: blocked.subtracting(oldBlocked), removed: oldBlocked.subtracting(blocked)))
        }
        return edits
    }

    /// Custom categories added, and each app or website that changed category. Apple's category items joining one
    /// (scanned ones matched later) aren't edits of the parents'.
    private static func categoryChanges(_ old: [ItemGroup], _ new: [ItemGroup]) -> [PolicyEdit] {
        let oldIDs = Set(old.map(\.id))
        let added = new.filter { !oldIDs.contains($0.id) }.map(\.name).sorted()
        func homes(_ groups: [ItemGroup]) -> [UUID: UUID] {
            var homes: [UUID: UUID] = [:]
            for group in groups { for item in group.moved { homes[item] = group.id } }
            return homes
        }
        let (before, after) = (homes(old), homes(new))
        let moves = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }
            .sorted { $0.uuidString < $1.uuidString }
            .map { PolicyEdit.categoryMove(item: $0, from: before[$0], to: after[$0]) }
        return (added.isEmpty ? [] : [.categoriesAdded(added)]) + moves
    }

    private static func changes<T: Identifiable & Equatable>(
        _ old: [T], _ new: [T], added: (T) -> PolicyEdit, removed: (T) -> PolicyEdit, changed: (T, T) -> PolicyEdit?
    ) -> [PolicyEdit] {
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let newIDs = Set(new.map(\.id))
        return old.filter { !newIDs.contains($0.id) }.map(removed) + new.compactMap { value in
            guard let previous = oldByID[value.id] else { return added(value) }
            return previous == value ? nil : changed(previous, value)
        }
    }

    /// One line for the history, then lines of detail. `name` names an item (app, website or category) or a group.
    public func describe(calendar: Calendar = .current, name: (UUID) -> String) -> (title: String, details: [String]) {
        func names(_ ids: Set<UUID>) -> String { ids.map(name).sorted().joined(separator: ", ") }
        func listChange(_ added: Set<UUID>, _ removed: Set<UUID>) -> [String] {
            (added.isEmpty ? [] : ["Added \(names(added))"]) + (removed.isEmpty ? [] : ["Removed \(names(removed))"])
        }
        switch self {
        case let .enforcement(on):
            return (on ? "Turned enforcement on" : "Turned enforcement off", [])
        case let .downtimeAdded(window):
            return ("Added Downtime \u{201C}\(window.name)\u{201D}",
                    [window.schedule(calendar: calendar)] + (window.isWholePhone ? [] : ["Only \(names(window.items))"]))
        case let .downtimeRemoved(window):
            return ("Removed Downtime \u{201C}\(window.name)\u{201D}", [window.schedule(calendar: calendar)])
        case let .downtimeChanged(old, new):
            var details: [String] = []
            if old.name != new.name { details.append("Renamed from \u{201C}\(old.name)\u{201D}") }
            let (from, to) = (old.schedule(calendar: calendar), new.schedule(calendar: calendar))
            if from != to { details.append("\(from) → \(to)") }
            if old.isWholePhone != new.isWholePhone {
                details.append(new.isWholePhone ? "Now the whole phone" : "Now only \(names(new.items))")
            } else {
                details += listChange(new.items.subtracting(old.items), old.items.subtracting(new.items))
            }
            return ("Changed Downtime \u{201C}\(new.name)\u{201D}", details)
        case let .limitAdded(limit):
            var details = ["\(Self.minutes(limit.minutes)) a day" + (limit.enabled ? "" : ", off")]
            details += limit.weekdayMinutes.sorted { $0.key < $1.key }.map {
                "\(calendar.weekdaySymbols[$0.key - 1]): \(Self.minutes($0.value))"
            }
            if !limit.warningPercents.isEmpty { details.append(Self.warnings(limit.warningPercents)) }
            details.append(names(limit.items))
            return ("Added limit \u{201C}\(limit.name)\u{201D}", details)
        case let .limitRemoved(limit):
            return ("Removed limit \u{201C}\(limit.name)\u{201D}", ["\(Self.minutes(limit.minutes)) a day, \(names(limit.items))"])
        case let .limitChanged(old, new):
            var details: [String] = []
            if old.name != new.name { details.append("Renamed from \u{201C}\(old.name)\u{201D}") }
            if old.enabled != new.enabled { details.append(new.enabled ? "Turned on" : "Turned off") }
            if old.minutes != new.minutes { details.append("\(Self.minutes(old.minutes)) → \(Self.minutes(new.minutes)) a day") }
            for weekday in 1...7 where old.weekdayMinutes[weekday] != new.weekdayMinutes[weekday] {
                let (from, to) = (old.weekdayMinutes[weekday].map(Self.minutes) ?? "same",
                                  new.weekdayMinutes[weekday].map(Self.minutes) ?? "same")
                details.append("\(calendar.weekdaySymbols[weekday - 1]): \(from) → \(to)")
            }
            if old.warningPercents != new.warningPercents {
                details.append(new.warningPercents.isEmpty ? "No warnings" : Self.warnings(new.warningPercents))
            }
            details += listChange(new.items.subtracting(old.items), old.items.subtracting(new.items))
            return ("Changed limit \u{201C}\(new.name)\u{201D}", details)
        case let .groupAdded(group):
            return ("Added group \u{201C}\(group.name)\u{201D}", group.items.isEmpty ? [] : [names(group.items)])
        case let .groupRemoved(group):
            return ("Removed group \u{201C}\(group.name)\u{201D}", group.items.isEmpty ? [] : [names(group.items)])
        case let .groupChanged(old, new):
            var details: [String] = []
            if old.name != new.name { details.append("Renamed from \u{201C}\(old.name)\u{201D}") }
            details += listChange(new.items.subtracting(old.items), old.items.subtracting(new.items))
            return ("Changed group \u{201C}\(new.name)\u{201D}", details)
        case let .categoriesAdded(names):
            return (names.count == 1 ? "Added category \u{201C}\(names[0])\u{201D}" : "Set up categories",
                    names.count == 1 ? [] : [names.joined(separator: ", ")])
        case let .categoryMove(item, from, to):
            let home = "Apple's category"
            return ("Moved \(name(item)) to \(to.map(name) ?? home)", ["From \(from.map(name) ?? home)"])
        case let .breaks(old, new):
            func rule(_ rule: BreakRule?) -> String {
                guard let rule, rule.enabled else { return "Off" }
                return "\(Self.minutes(rule.breakMinutes)) after \(Self.minutes(rule.useMinutes)) of use"
            }
            guard let new, new.enabled else { return ("Turned breaks off", ["Was \(rule(old))"]) }
            return (old?.enabled == true ? "Changed breaks" : "Turned breaks on",
                    [rule(new)] + (old?.enabled == true ? ["Was \(rule(old))"] : []))
        case let .alwaysAllowed(added, removed):
            return ("Changed Always Allowed", listChange(added, removed))
        case let .uncounted(added, removed):
            return ("Changed Uncounted", listChange(added, removed))
        case let .blocked(added, removed):
            return ("Changed Blocked", listChange(added, removed))
        case let .restriction(name, from, to):
            return ("\(name): \(to)", ["Was \(from)"])
        case let .websites(list, added, removed):
            return ("Changed \(list)", (added.isEmpty ? [] : ["Added \(added.joined(separator: ", "))"])
                + (removed.isEmpty ? [] : ["Removed \(removed.joined(separator: ", "))"]))
        case let .ruleSetsSetUp(names):
            return ("Set up rulesets", [names.joined(separator: ", ")])
        case let .ruleSetAdded(set):
            return ("Added ruleset \u{201C}\(set.name)\u{201D}", [set.days(calendar: calendar)])
        case let .ruleSetRemoved(set):
            return ("Removed ruleset \u{201C}\(set.name)\u{201D}", [set.days(calendar: calendar)])
        case let .ruleSetChanged(old, new):
            var details: [String] = []
            if old.name != new.name { details.append("Renamed from \u{201C}\(old.name)\u{201D}") }
            if old.weekdays != new.weekdays { details.append("\(old.days(calendar: calendar)) → \(new.days(calendar: calendar))") }
            return ("Changed ruleset \u{201C}\(new.name)\u{201D}", details)
        case let .inRuleSet(ruleSet, edit):
            let inner = edit.describe(calendar: calendar, name: name)
            return ("\(ruleSet): \(inner.title)", inner.details)
        case let .ruleSetChosen(choice):
            guard let choice else { return ("Back to each day's own ruleset", []) }
            return ("Switched to \u{201C}\(choice.name)\u{201D}", [choice.span(calendar: calendar)])
        }
    }

    static func minutes(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    /// "Warns at 75%, 90%".
    static func warnings(_ percents: [Int]) -> String {
        "Warns at " + percents.sorted().map { "\($0)%" }.joined(separator: ", ")
    }
}

extension DowntimeWindow {
    /// "21:30–7:00, every day" or "8:00–15:00, Mon Tue Wed".
    public func schedule(calendar: Calendar = .current) -> String {
        let days = weekdays.isEmpty || weekdays.count == 7 ? "every day"
            : weekdays.sorted().map { calendar.shortWeekdaySymbols[$0 - 1] }.joined(separator: " ")
        return "\(RuleCondition.clock(startMinute))–\(RuleCondition.clock(endMinute)), \(days)"
    }
}

extension Restrictions {
    /// Apple's rating values (see `Restrictions`) and their names.
    public static let appRatings = [(100, "4+"), (200, "9+"), (300, "12+"), (600, "17+")]
    public static let movieRatings = [(100, "G"), (200, "PG"), (300, "PG-13"), (400, "R")]
    public static let tvRatings = [(100, "TV-Y"), (200, "TV-Y7"), (300, "TV-G"), (400, "TV-PG"), (500, "TV-14")]

    /// Each setting as the Content & Privacy screen names it, with its value as shown. The web filter's lists are
    /// compared apart (`WebFilter.lists`).
    static var settings: [(name: String, value: (Restrictions) -> String)] {
        func toggle(_ name: String, _ keyPath: KeyPath<Restrictions, Bool>) -> (name: String, value: (Restrictions) -> String) {
            (name, { $0[keyPath: keyPath] ? "On" : "Off" })
        }
        func rating(_ name: String, _ keyPath: KeyPath<Restrictions, Int?>, _ names: [(Int, String)])
            -> (name: String, value: (Restrictions) -> String) {
            (name, { restrictions in
                restrictions[keyPath: keyPath].map { value in names.first { $0.0 == value }?.1 ?? "\(value)" } ?? "All"
            })
        }
        return [
            toggle("Block installing apps", \.denyAppInstallation),
            toggle("Block deleting apps", \.denyAppRemoval),
            toggle("Block in-app purchases", \.denyInAppPurchases),
            toggle("Always require password", \.requirePasswordForPurchases),
            rating("Apps up to", \.maximumAppRating, appRatings),
            toggle("Block explicit music, podcasts and books", \.denyExplicitContent),
            rating("Movies up to", \.maximumMovieRating, movieRatings),
            rating("TV shows up to", \.maximumTVShowRating, tvRatings),
            toggle("Block sexual content in books", \.denyBookstoreErotica),
            toggle("Block Apple Music", \.denyMusicService),
            ("Websites", { $0.webFilter.modeTitle }),
            toggle("Block Safari AutoFill", \.denySafariAutoFill),
            toggle("Block Siri", \.denySiri),
            toggle("Block multiplayer games", \.denyMultiplayerGaming),
            toggle("Block adding Game Center friends", \.denyAddingFriends),
            toggle("Lock accounts", \.lockAccounts),
            toggle("Lock passcode", \.lockPasscode),
            toggle("Lock cellular data per app", \.lockAppCellularData),
            toggle("Lock cellular plan", \.lockCellularPlan),
            toggle("Lock eSIM", \.lockESIM),
            toggle("Require automatic date and time", \.requireAutomaticDateAndTime),
        ]
    }
}

extension WebFilter {
    public var modeTitle: String {
        switch self {
        case .unrestricted: "Unrestricted"
        case .limitAdult: "Limit adult websites"
        case .allowedOnly: "Allowed websites only"
        }
    }

    static let listNames = ["websites always allowed", "websites never allowed", "allowed websites"]

    /// Domain lists by name, in `listNames`.
    var lists: [String: [String]] {
        switch self {
        case .unrestricted: [:]
        case let .limitAdult(allowed, blocked): [Self.listNames[0]: allowed, Self.listNames[1]: blocked]
        case let .allowedOnly(allowed): [Self.listNames[2]: allowed]
        }
    }
}
