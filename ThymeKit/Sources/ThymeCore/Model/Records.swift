import Foundation

// The synced record types (PLAN.md §4.4). Each maps 1:1 to a CloudKit record type in Shared/Sync.

public struct Kid: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var displayName: String
    public var colorIndex: Int
    public var deviceName: String
    /// Fake kids created by single-phone test mode or the replay tool (PLAN.md §7.1).
    public var isTest: Bool

    public init(id: UUID = UUID(), displayName: String, colorIndex: Int = 0, deviceName: String = "", isTest: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.colorIndex = colorIndex
        self.deviceName = deviceName
        self.isTest = isTest
    }
}

public enum ItemKind: String, Codable, Sendable, CaseIterable {
    case app, domain, category
}

/// One app, web domain or category from a scan. `id` is our stable key; tokens can expire and be replaced.
public struct TrackedItem: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kidID: UUID
    public var kind: ItemKind
    /// JSON-encoded ApplicationToken / WebDomainToken / ActivityCategoryToken.
    public var tokenData: Data?
    public var nickname: String?
    /// Stable per-kid number for the "App #37" fallback name.
    public var ordinal: Int
    public var firstSeenEpoch: UUID
    public var active: Bool

    public init(id: UUID = UUID(), kidID: UUID, kind: ItemKind, tokenData: Data?, nickname: String? = nil,
                ordinal: Int, firstSeenEpoch: UUID, active: Bool = true) {
        self.id = id
        self.kidID = kidID
        self.kind = kind
        self.tokenData = tokenData
        self.nickname = nickname
        self.ordinal = ordinal
        self.firstSeenEpoch = firstSeenEpoch
        self.active = active
    }

    public var fallbackName: String {
        switch kind {
        case .app: "App #\(ordinal)"
        case .domain: "Website #\(ordinal)"
        case .category: "Category #\(ordinal)"
        }
    }
}

/// One registration of ladders (a scan or re-scan). Fires record which epoch they came from.
public struct LadderEpoch: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kidID: UUID
    public var startedAt: Date
    public var activityNames: [String]
    public var itemIDs: [UUID]
    public var spec: LadderSpec

    public init(id: UUID = UUID(), kidID: UUID, startedAt: Date, activityNames: [String], itemIDs: [UUID], spec: LadderSpec) {
        self.id = id
        self.kidID = kidID
        self.startedAt = startedAt
        self.activityNames = activityNames
        self.itemIDs = itemIDs
        self.spec = spec
    }
}

/// A threshold crossing: "item (or the whole phone, when `itemID` is nil) reached `minute` minutes today at `firedAt`".
public struct UsageFire: Codable, Sendable, Hashable, Identifiable {
    /// Equal to the journal entry's id, so uploads are idempotent.
    public var id: UUID
    public var kidID: UUID
    public var itemID: UUID?
    public var minute: Int
    public var firedAt: Date
    public var day: DayKey
    public var epochID: UUID?

    public init(id: UUID, kidID: UUID, itemID: UUID?, minute: Int, firedAt: Date, day: DayKey, epochID: UUID?) {
        self.id = id
        self.kidID = kidID
        self.itemID = itemID
        self.minute = minute
        self.firedAt = firedAt
        self.day = day
        self.epochID = epochID
    }

    public var isTotal: Bool { itemID == nil }
}

public enum HeartbeatSource: String, Codable, Sendable {
    case fire, backgroundRefresh, ping, launch, manual
}

public struct Heartbeat: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kidID: UUID
    public var at: Date
    public var source: HeartbeatSource
    /// "approved", "denied", "notDetermined".
    public var authStatus: String
    public var activeActivities: [String]
    public var expectedActivities: [String]
    public var appVersion: String
    public var backlogCount: Int
    public var lastFireAt: Date?

    public init(id: UUID = UUID(), kidID: UUID, at: Date, source: HeartbeatSource, authStatus: String,
                activeActivities: [String], expectedActivities: [String], appVersion: String,
                backlogCount: Int, lastFireAt: Date?) {
        self.id = id
        self.kidID = kidID
        self.at = at
        self.source = source
        self.authStatus = authStatus
        self.activeActivities = activeActivities
        self.expectedActivities = expectedActivities
        self.appVersion = appVersion
        self.backlogCount = backlogCount
        self.lastFireAt = lastFireAt
    }
}

public struct AlertRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kidID: UUID
    public var ruleID: UUID?
    public var itemID: UUID?
    public var at: Date
    public var title: String
    public var body: String

    public init(id: UUID = UUID(), kidID: UUID, ruleID: UUID?, itemID: UUID?, at: Date, title: String, body: String) {
        self.id = id
        self.kidID = kidID
        self.ruleID = ruleID
        self.itemID = itemID
        self.at = at
        self.title = title
        self.body = body
    }
}

/// A parent-initiated liveness check; the kid device answers with a `Heartbeat`.
public struct Ping: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kidID: UUID
    public var at: Date
    public var from: String

    public init(id: UUID = UUID(), kidID: UUID, at: Date, from: String) {
        self.id = id
        self.kidID = kidID
        self.at = at
        self.from = from
    }
}
