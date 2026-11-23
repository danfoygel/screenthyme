import Foundation

/// What ScreenThyme enforces on one kid's phone (PLAN.md §15): Downtime, App Limits, Always Allowed, blocked items
/// and Content & Privacy restrictions. Edited on parent phones and synced as one record, `Policy.<kid id>`.
/// Items are `TrackedItem` ids (apps, websites and categories found in Apple's activity data) or `ItemGroup` ids, which
/// stand for their items (`resolved`).
public struct Policy: Codable, Sendable, Hashable {
    public var kidID: UUID
    public var updatedAt: Date
    /// Off: nothing is blocked or restricted (the policy is kept).
    public var enabled: Bool
    public var downtime: [DowntimeWindow]
    public var alwaysAllowed: Set<UUID>
    public var limits: [AppLimit]
    public var blocked: Set<UUID>
    public var restrictions: Restrictions
    /// The parents' own categories, used in Downtime, limits, Always Allowed and Blocked (PLAN.md §15.8).
    public var groups: [ItemGroup]
    /// Saves made for some days only, each changing back at its end (`current(at:)`, PLAN.md §15.10).
    public var temporary: [TemporaryChange]

    public init(kidID: UUID, updatedAt: Date = Date(), enabled: Bool = true, downtime: [DowntimeWindow] = [],
                alwaysAllowed: Set<UUID> = [], limits: [AppLimit] = [], blocked: Set<UUID> = [],
                restrictions: Restrictions = Restrictions(), groups: [ItemGroup] = [], temporary: [TemporaryChange] = []) {
        self.kidID = kidID
        self.updatedAt = updatedAt
        self.enabled = enabled
        self.downtime = downtime
        self.alwaysAllowed = alwaysAllowed
        self.limits = limits
        self.blocked = blocked
        self.restrictions = restrictions
        self.groups = groups
        self.temporary = temporary
    }

    /// Policies saved before a field existed still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kidID = try container.decode(UUID.self, forKey: .kidID)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        downtime = try container.decode([DowntimeWindow].self, forKey: .downtime)
        alwaysAllowed = try container.decode(Set<UUID>.self, forKey: .alwaysAllowed)
        limits = try container.decode([AppLimit].self, forKey: .limits)
        blocked = try container.decode(Set<UUID>.self, forKey: .blocked)
        restrictions = try container.decode(Restrictions.self, forKey: .restrictions)
        groups = try container.decodeIfPresent([ItemGroup].self, forKey: .groups) ?? []
        temporary = try container.decodeIfPresent([TemporaryChange].self, forKey: .temporary) ?? []
    }

    /// `ids` with each group's id replaced by its items.
    public func expandingGroups(_ ids: Set<UUID>) -> Set<UUID> {
        guard !groups.isEmpty else { return ids }
        var result = ids
        for group in groups where result.remove(group.id) != nil { result.formUnion(group.items) }
        return result
    }

    /// The policy as enforced: Always Allowed, Blocked and limits name items, never groups. Downtime windows keep
    /// theirs: a window of an emptied group must still block nothing rather than the whole phone, so the planner
    /// expands them (`downtimeItems`). Resolving twice changes nothing.
    public var resolved: Policy {
        var policy = self
        policy.alwaysAllowed = expandingGroups(alwaysAllowed)
        policy.blocked = expandingGroups(blocked)
        for index in policy.limits.indices { policy.limits[index].items = expandingGroups(limits[index].items) }
        return policy
    }

    /// `resolved`, following new tokens first (`followingNewTokens`).
    public func resolved(items: [UUID: TrackedItem]) -> Policy {
        followingNewTokens(items: items).resolved
    }

    /// The policy with each scanned item that lost its token replaced by the scanned items with a token matched to the
    /// same app, website or category: a later app scan gave it a new token, and Downtime, limits, Always Allowed,
    /// Blocked and groups follow it there. One with no such item stays, for an app no longer on the kid's phone
    /// (`staleItems`). Following twice changes nothing.
    public func followingNewTokens(items: [UUID: TrackedItem]) -> Policy {
        let stale = Self.staleItems(allItemIDs, items: items).compactMap { items[$0] }.filter { $0.match != nil }
        guard !stale.isEmpty else { return self }
        var live: [UUID: [UUID]] = [:]
        for item in items.values { if let match = item.liveMatch { live[match, default: []].append(item.id) } }
        var replacements: [UUID: [UUID]] = [:]
        for item in stale {
            guard let ids = live[item.match!]?.filter({ items[$0]?.kind == item.kind }), !ids.isEmpty else { continue }
            replacements[item.id] = ids
        }
        guard !replacements.isEmpty else { return self }
        return replacingItems(replacements)
    }

    /// Temporary changes follow too, so what they added or removed still changes back.
    private func replacingItems(_ replacements: [UUID: [UUID]]) -> Policy {
        func follow(_ ids: Set<UUID>) -> Set<UUID> {
            Set(ids.flatMap { replacements[$0] ?? [$0] })
        }
        var policy = self
        policy.alwaysAllowed = follow(alwaysAllowed)
        policy.blocked = follow(blocked)
        for index in policy.limits.indices { policy.limits[index].items = follow(limits[index].items) }
        for index in policy.downtime.indices { policy.downtime[index].items = follow(downtime[index].items) }
        for index in policy.groups.indices { policy.groups[index].items = follow(groups[index].items) }
        for index in policy.temporary.indices {
            policy.temporary[index].before = temporary[index].before.replacingItems(replacements)
            policy.temporary[index].after = temporary[index].after.replacingItems(replacements)
        }
        return policy
    }

    /// Scanned items in `ids` that lost their token. In a policy that followed new tokens, they had none to follow: apps
    /// no longer on the kid's phone, or not picked in the latest app scan. They block and allow nothing.
    public static func staleItems(_ ids: Set<UUID>, items: [UUID: TrackedItem]) -> Set<UUID> {
        ids.filter { id in items[id].map { $0.isScanned && $0.tokenData == nil } ?? false }
    }

    /// Every item id the policy names, in groups and temporary changes too.
    var allItemIDs: Set<UUID> {
        var ids = alwaysAllowed.union(blocked)
        for limit in limits { ids.formUnion(limit.items) }
        for window in downtime { ids.formUnion(window.items) }
        for group in groups { ids.formUnion(group.items) }
        for change in temporary { ids.formUnion(change.before.allItemIDs.union(change.after.allItemIDs)) }
        return ids
    }

    /// What `window` blocks, as items; nil for the whole phone.
    public func downtimeItems(_ window: DowntimeWindow) -> Set<UUID>? {
        window.isWholePhone ? nil : expandingGroups(window.items)
    }

    /// Whether `itemID` is Always Allowed, itself or through a group (following new tokens).
    public func isAlwaysAllowed(_ itemID: UUID, items: [UUID: TrackedItem]) -> Bool {
        resolved(items: items).alwaysAllowed.contains(itemID)
    }

    /// The policy with an approved request to always allow an app applied: the app is Always Allowed, and no longer
    /// Blocked. Any other grant leaves the policy as it is.
    public func applying(_ grant: TimeGrant) -> Policy {
        guard grant.approved, grant.reason == .alwaysAllow, let itemID = grant.itemID else { return self }
        var policy = self
        policy.alwaysAllowed.insert(itemID)
        policy.blocked.remove(itemID)
        return policy
    }

    /// Removes a group and every use of it.
    public mutating func removeGroup(_ id: UUID) {
        groups.removeAll { $0.id == id }
        alwaysAllowed.remove(id)
        blocked.remove(id)
        for index in limits.indices { limits[index].items.remove(id) }
        for index in downtime.indices { downtime[index].items.remove(id) }
    }
}

/// A parent's own category: apps, websites and Apple's categories under one name, like "Games" or "Homework
/// distractions". An app may be in several groups. Groups don't contain groups.
public struct ItemGroup: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// `TrackedItem` ids.
    public var items: Set<UUID>

    public init(id: UUID = UUID(), name: String, items: Set<UUID> = []) {
        self.id = id
        self.name = name
        self.items = items
    }
}

/// Minutes of day; `endMinute < startMinute` wraps past midnight. `weekdays` uses Calendar numbering (1 = Sunday),
/// refers to the day the window starts, and empty means every day.
public struct DowntimeWindow: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var startMinute: Int
    public var endMinute: Int
    public var weekdays: Set<Int>
    /// What the window blocks: empty is the whole phone but Always Allowed; otherwise only these apps, websites,
    /// categories and groups (PLAN.md §15.8).
    public var items: Set<UUID>

    public init(id: UUID = UUID(), name: String, startMinute: Int, endMinute: Int, weekdays: Set<Int> = [],
                items: Set<UUID> = []) {
        self.id = id
        self.name = name
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.weekdays = weekdays
        self.items = items
    }

    /// Windows saved before a field existed still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        startMinute = try container.decode(Int.self, forKey: .startMinute)
        endMinute = try container.decode(Int.self, forKey: .endMinute)
        weekdays = try container.decode(Set<Int>.self, forKey: .weekdays)
        items = try container.decodeIfPresent(Set<UUID>.self, forKey: .items) ?? []
    }

    /// Blocks the whole phone, not only some apps.
    public var isWholePhone: Bool { items.isEmpty }
}

/// A daily budget shared by its items, like Apple's App Limits.
public struct AppLimit: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var items: Set<UUID>
    /// Every app and website but Always Allowed ones, like Apple's All Apps & Categories; `items` is then ignored.
    public var allApps: Bool
    public var minutes: Int
    /// Per-weekday budgets (Calendar numbering) that replace `minutes` on those days.
    public var weekdayMinutes: [Int: Int]
    public var enabled: Bool

    public init(id: UUID = UUID(), name: String, items: Set<UUID>, allApps: Bool = false, minutes: Int,
                weekdayMinutes: [Int: Int] = [:], enabled: Bool = true) {
        self.id = id
        self.name = name
        self.items = items
        self.allApps = allApps
        self.minutes = minutes
        self.weekdayMinutes = weekdayMinutes
        self.enabled = enabled
    }

    /// Policies saved before a field existed still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        items = try container.decode(Set<UUID>.self, forKey: .items)
        allApps = try container.decodeIfPresent(Bool.self, forKey: .allApps) ?? false
        minutes = try container.decode(Int.self, forKey: .minutes)
        weekdayMinutes = try container.decodeIfPresent([Int: Int].self, forKey: .weekdayMinutes) ?? [:]
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    public func minutes(on weekday: Int) -> Int {
        weekdayMinutes[weekday] ?? minutes
    }
}

/// Content & Privacy restrictions available to third-party apps (ManagedSettings). `nil` ratings mean no limit.
/// Rating values are Apple's: apps 100 = 4+, 200 = 9+, 300 = 12+, 600 = 17+; US movies 100 = G … 500 = NC-17;
/// US TV 100 = TV-Y … 600 = TV-MA.
public struct Restrictions: Codable, Sendable, Hashable {
    public var denyAppInstallation = false
    public var denyAppRemoval = false
    public var denyInAppPurchases = false
    public var requirePasswordForPurchases = false
    public var maximumAppRating: Int?
    public var denyExplicitContent = false
    public var maximumMovieRating: Int?
    public var maximumTVShowRating: Int?
    public var denyBookstoreErotica = false
    public var denyMusicService = false
    public var webFilter: WebFilter = .unrestricted
    public var denySiri = false
    public var denyMultiplayerGaming = false
    public var denyAddingFriends = false
    public var lockAccounts = false
    public var lockPasscode = false
    public var lockAppCellularData = false
    public var lockCellularPlan = false
    public var lockESIM = false
    public var requireAutomaticDateAndTime = false
    public var denySafariAutoFill = false

    public init() {}

    public var isEmpty: Bool { self == Restrictions() }
}

public enum WebFilter: Codable, Sendable, Hashable {
    case unrestricted
    /// Apple's adult-content filter, plus domains always allowed and always blocked.
    case limitAdult(allowed: [String], blocked: [String])
    case allowedOnly([String])
}

/// Why something is blocked: what a block page says and what a request for more time asks to lift.
public enum BlockReason: Codable, Sendable, Hashable {
    case downtime(UUID)
    case limit(UUID)
    case blocked
    /// Not a block: the kid asks for the app to be Always Allowed. Approving it changes the policy
    /// (`Policy.applying`); the grant lets nothing through by itself.
    case alwaysAllow
}

/// The kid asked for more time, in ScreenThyme (opened from a block page). `minutes == nil` asks for the rest of the day
/// (or of Downtime).
public struct TimeRequest: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kidID: UUID
    public var itemID: UUID?
    public var reason: BlockReason
    public var minutes: Int?
    public var at: Date
    /// The kid's words to the parents.
    public var note: String?

    public init(id: UUID = UUID(), kidID: UUID, itemID: UUID?, reason: BlockReason, minutes: Int?, at: Date,
                note: String? = nil) {
        self.id = id
        self.kidID = kidID
        self.itemID = itemID
        self.reason = reason
        self.minutes = minutes
        self.at = at
        self.note = note
    }
}

/// A parent's answer, saved as `TimeGrant.<request id>` so the kid's phone can fetch it by name.
/// For a limit, the item is let through it for `minutes` of its use (with no item, `minutes` are added to the limit
/// today); for the rest of today when `minutes == nil`. For Downtime, the item (or with no item, the whole phone) is
/// exempt for `minutes` of use or of the clock, or until the window ends when `minutes == nil`.
public struct TimeGrant: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID { requestID }
    public var requestID: UUID
    public var kidID: UUID
    public var itemID: UUID?
    public var reason: BlockReason
    public var approved: Bool
    public var minutes: Int?
    public var at: Date
    public var by: String

    public init(request: TimeRequest, approved: Bool, minutes: Int?, at: Date, by: String) {
        self.requestID = request.id
        self.kidID = request.kidID
        self.itemID = request.itemID
        self.reason = request.reason
        self.approved = approved
        self.minutes = minutes
        self.at = at
        self.by = by
    }
}

/// A "one more minute" the kid took on a block page (`ExtraMinute`), kept on the kid's phone and synced, so the app's
/// details show it on parents' phones too. `itemID` is what the press named, as in `ExtraMinute`.
public struct ExtraMinuteUse: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kidID: UUID
    public var itemID: UUID?
    public var reason: BlockReason
    public var at: Date
    public var minutes: Int

    public init(id: UUID = UUID(), kidID: UUID, itemID: UUID?, reason: BlockReason, at: Date, minutes: Int) {
        self.id = id
        self.kidID = kidID
        self.itemID = itemID
        self.reason = reason
        self.at = at
        self.minutes = minutes
    }
}
