import Foundation

/// What ScreenThyme enforces on one kid's phone (PLAN.md §15): Downtime, App Limits, Always Allowed, blocked items
/// and Content & Privacy restrictions. Edited on parent phones and synced as one record, `Policy.<kid id>`.
/// Items are `TrackedItem` ids: apps, websites and categories found in Apple's activity data.
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

    public init(kidID: UUID, updatedAt: Date = Date(), enabled: Bool = true, downtime: [DowntimeWindow] = [],
                alwaysAllowed: Set<UUID> = [], limits: [AppLimit] = [], blocked: Set<UUID> = [],
                restrictions: Restrictions = Restrictions()) {
        self.kidID = kidID
        self.updatedAt = updatedAt
        self.enabled = enabled
        self.downtime = downtime
        self.alwaysAllowed = alwaysAllowed
        self.limits = limits
        self.blocked = blocked
        self.restrictions = restrictions
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

    public init(id: UUID = UUID(), name: String, startMinute: Int, endMinute: Int, weekdays: Set<Int> = []) {
        self.id = id
        self.name = name
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.weekdays = weekdays
    }
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
/// For a limit, `minutes` are added to that limit today. For Downtime, the item (or with no item, the whole phone) is
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
