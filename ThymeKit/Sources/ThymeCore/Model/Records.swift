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
    case app, domain
    /// One of Apple's activity categories ("Social"), a target for limits and Always Allowed.
    case category

    public var title: String {
        switch self {
        case .app: "App"
        case .domain: "Website"
        case .category: "Category"
        }
    }
}

/// An app, website or category seen in Apple's activity data on a kid's phone (discovered automatically), or chosen in
/// the app scan there (`isScanned`: a token, no bundle ID).
public struct TrackedItem: Codable, Sendable, Hashable, Identifiable {
    /// Derived from kid and `identifier` (see `TrackedItem.id(kid:kind:identifier:)`), so every device agrees.
    public var id: UUID
    public var kidID: UUID
    public var kind: ItemKind
    /// Bundle ID ("com.burbn.instagram"), domain ("www.youtube.com") or category name ("Social").
    public var identifier: String
    /// Apple's display name, when the data includes one.
    public var name: String?
    /// JSON-encoded ApplicationToken / WebDomainToken / ActivityCategoryToken, for `Label` (icon and name) on parent
    /// phones and for shields on the kid's phone.
    public var tokenData: Data?
    /// For apps and websites: the identifier of their category item, so category limits count them.
    public var category: String?
    public var nickname: String?
    public var firstSeen: Date
    /// For a scanned item: the item from Apple's data for the same app, learned by watching use (`TokenMatching`).
    public var match: UUID?

    public init(kidID: UUID, kind: ItemKind, identifier: String, name: String? = nil, tokenData: Data? = nil,
                category: String? = nil, nickname: String? = nil, firstSeen: Date) {
        self.id = Self.id(kid: kidID, kind: kind, identifier: identifier)
        self.kidID = kidID
        self.kind = kind
        self.identifier = identifier
        self.name = name
        self.tokenData = tokenData
        self.category = category
        self.nickname = nickname
        self.firstSeen = firstSeen
    }

    /// Identifier prefix of items from the app scan on the kid's phone (`FamilyActivityPicker`), which gives a token
    /// but no bundle ID or name; the rest of the identifier is a hash of the token.
    public static let scannedPrefix = "token:"

    /// From the app scan: has a token for shields, but no usage in Apple's data (that has bundle IDs, no tokens).
    public var isScanned: Bool { identifier.hasPrefix(Self.scannedPrefix) }

    public static func id(kid: UUID, kind: ItemKind, identifier: String) -> UUID {
        Replay.stableUUID("item", kid.uuidString, kind.rawValue, identifier)
    }

    /// Nickname, Apple's name, or a readable form of the identifier ("com.burbn.instagram" → "instagram").
    public var displayName: String {
        if let nickname { return nickname }
        if let name { return name }
        if isScanned { return kind.title }
        switch kind {
        case .app: return BuiltInApps.names[identifier] ?? identifier.split(separator: ".").last.map(String.init) ?? identifier
        case .domain: return identifier.hasPrefix("www.") ? String(identifier.dropFirst(4)) : identifier
        case .category: return identifier
        }
    }
}

/// One monitoring registration (start, re-register, midnight). Heartbeats compare its activities with iOS's.
public struct LadderEpoch: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kidID: UUID
    public var startedAt: Date
    public var activityNames: [String]

    public init(id: UUID = UUID(), kidID: UUID, startedAt: Date, activityNames: [String]) {
        self.id = id
        self.kidID = kidID
        self.startedAt = startedAt
        self.activityNames = activityNames
    }
}

/// "Item was used `seconds` seconds between `start` and `end`": the difference between two of Apple's activity
/// fetches, within one hour segment. A day's samples for an item add up to Apple's exact total.
public struct UsageSample: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kidID: UUID
    public var itemID: UUID
    public var day: DayKey
    public var start: Date
    public var end: Date
    public var seconds: Double

    public init(id: UUID, kidID: UUID, itemID: UUID, day: DayKey, start: Date, end: Date, seconds: Double) {
        self.id = id
        self.kidID = kidID
        self.itemID = itemID
        self.day = day
        self.start = start
        self.end = end
        self.seconds = seconds
    }
}

/// A total-use threshold crossing: "the phone reached `minute` minutes of use today at `firedAt`". Minute 0 marks a
/// tracking start. `itemID` is only set on records from the old per-app ladders, which are ignored.
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
    /// The phone's charge, 0–1, when the heartbeat was sent; nil if iOS didn't say.
    public var batteryLevel: Double?

    public init(id: UUID = UUID(), kidID: UUID, at: Date, source: HeartbeatSource, authStatus: String,
                activeActivities: [String], expectedActivities: [String], appVersion: String,
                backlogCount: Int, lastFireAt: Date?, batteryLevel: Double? = nil) {
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
        self.batteryLevel = batteryLevel
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

/// What one of our processes used in a day, from the kernel's per-process counters.
public struct EnergyUsage: Codable, Sendable, Hashable {
    public var energyNanojoules: UInt64 = 0
    public var cpuNanoseconds: UInt64 = 0
    /// CPU wake-ups from idle and interrupts, as the kernel counts them for our process.
    public var wakeups: UInt64 = 0
    /// Extension callbacks (threshold fires, interval starts and ends).
    public var callbacks = 0
    /// Processes iOS started for us.
    public var launches = 0

    public init() {}

    public var joules: Double { Double(energyNanojoules) / 1e9 }
    public var milliwattHours: Double { joules / 3.6 }
    public var cpuSeconds: Double { Double(cpuNanoseconds) / 1e9 }

    mutating func add(_ delta: EnergyCounters) {
        energyNanojoules += delta.energyNanojoules
        cpuNanoseconds += delta.cpuNanoseconds
        wakeups += delta.wakeups
    }

    public static func + (lhs: EnergyUsage, rhs: EnergyUsage) -> EnergyUsage {
        var sum = lhs
        sum.energyNanojoules += rhs.energyNanojoules
        sum.cpuNanoseconds += rhs.cpuNanoseconds
        sum.wakeups += rhs.wakeups
        sum.callbacks += rhs.callbacks
        sum.launches += rhs.launches
        return sum
    }
}

/// Energy our own code used on a kid's phone in one day. It leaves out work iOS does for us in its own processes:
/// Screen Time's usage tracking, and CloudKit's network transfers (made by the system's sync daemon).
public struct EnergyReport: Codable, Sendable, Hashable, Identifiable {
    /// One record per kid per day, overwritten as the day goes on.
    public var id: UUID
    public var kidID: UUID
    public var day: DayKey
    public var updatedAt: Date
    /// `hw.machine`, e.g. "iPhone14,6".
    public var deviceModel: String
    public var monitor: EnergyUsage
    public var app: EnergyUsage

    public init(kidID: UUID, day: DayKey, updatedAt: Date, deviceModel: String, monitor: EnergyUsage, app: EnergyUsage) {
        self.id = Replay.stableUUID("energy", kidID.uuidString, day.description)
        self.kidID = kidID
        self.day = day
        self.updatedAt = updatedAt
        self.deviceModel = deviceModel
        self.monitor = monitor
        self.app = app
    }

    public var total: EnergyUsage { monitor + app }

    /// Share of a full charge, for phones whose battery capacity we know.
    public var batteryFraction: Double? {
        BatteryCapacity.wattHours[deviceModel].map { total.joules / ($0 * 3600) }
    }
}

public enum BatteryCapacity {
    /// Rated capacity in watt-hours by model identifier, for the family's kid phones. Others show energy alone.
    public static let wattHours: [String: Double] = [
        "iPhone14,6": 7.82,  // iPhone SE (3rd generation): 2,018 mAh at 3.88 V
    ]
}
