import Foundation

public enum LinkRole: String, Codable, Sendable {
    case kid, parent
}

/// The first message each phone sends on a connection.
public struct LinkHello: Codable, Sendable, Hashable {
    public static let currentVersion = 1

    public var version: Int
    public var role: LinkRole
    /// On a kid phone: the kid it captures for.
    public var kidID: UUID?
    /// "Emma", "Parent A": for status lines.
    public var name: String
    /// Fresh for each connection; both phones' nonces make that connection's keys.
    public var nonce: Data
    public var sentAt: Date

    public init(role: LinkRole, kidID: UUID?, name: String, nonce: Data = LinkHello.makeNonce(), sentAt: Date = Date()) {
        self.version = Self.currentVersion
        self.role = role
        self.kidID = kidID
        self.name = name
        self.nonce = nonce
        self.sentAt = sentAt
    }

    public static func makeNonce() -> Data {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    }
}

/// Records one phone sends another: what the other phone would otherwise fetch from CloudKit. A kid phone sends its
/// usage, heartbeat, alerts and requests for more time; a parent phone sends that kid's rules, policy and answers.
/// Every record has the same id it has in CloudKit, so the CloudKit copy that arrives later just overwrites it.
public struct LinkBundle: Codable, Sendable, Hashable {
    public var kids: [Kid] = []
    public var items: [TrackedItem] = []
    public var epochs: [LadderEpoch] = []
    public var fires: [UsageFire] = []
    public var samples: [UsageSample] = []
    public var heartbeats: [Heartbeat] = []
    public var alerts: [AlertRecord] = []
    public var requests: [TimeRequest] = []
    public var ruleSets: [RuleSet] = []
    public var policies: [Policy] = []
    public var grants: [TimeGrant] = []

    public init() {}

    public var isEmpty: Bool { count == 0 }

    public var count: Int {
        kids.count + items.count + epochs.count + fires.count + samples.count + heartbeats.count + alerts.count
            + requests.count + ruleSets.count + policies.count + grants.count
    }

    /// Keeps only the records about one kid: a phone accepts nothing about other kids from a peer.
    public func only(kid: UUID) -> LinkBundle {
        var copy = self
        copy.kids = kids.filter { $0.id == kid }
        copy.items = items.filter { $0.kidID == kid }
        copy.epochs = epochs.filter { $0.kidID == kid }
        copy.fires = fires.filter { $0.kidID == kid }
        copy.samples = samples.filter { $0.kidID == kid }
        copy.heartbeats = heartbeats.filter { $0.kidID == kid }
        copy.alerts = alerts.filter { $0.kidID == kid }
        copy.requests = requests.filter { $0.kidID == kid }
        copy.ruleSets = ruleSets.filter { $0.kidID == kid }
        copy.policies = policies.filter { $0.kidID == kid }
        copy.grants = grants.filter { $0.kidID == kid }
        return copy
    }
}

/// What a connection already carried, so later bundles hold only new or changed records.
public struct LinkSentFilter: Sendable {
    private var sent: [String: Int] = [:]

    public init() {}

    public mutating func unsent(_ bundle: LinkBundle) -> LinkBundle {
        var out = LinkBundle()
        out.kids = filter(bundle.kids, "Kid", id: \.id)
        out.items = filter(bundle.items, "TrackedItem", id: \.id)
        out.epochs = filter(bundle.epochs, "LadderEpoch", id: \.id)
        out.fires = filter(bundle.fires, "UsageFire", id: \.id)
        out.samples = filter(bundle.samples, "UsageSample", id: \.id)
        out.heartbeats = filter(bundle.heartbeats, "Heartbeat", id: \.id)
        out.alerts = filter(bundle.alerts, "Alert", id: \.id)
        out.requests = filter(bundle.requests, "TimeRequest", id: \.id)
        // A rule set's date changes every time one is built; only its rules matter.
        out.ruleSets = filter(bundle.ruleSets, "RuleSet", id: \.kidID, content: { Set($0.rules) })
        out.policies = filter(bundle.policies, "Policy", id: \.kidID)
        out.grants = filter(bundle.grants, "TimeGrant", id: \.requestID)
        return out
    }

    /// Forgets everything, so the next bundle is sent in full (after the peer reconnects).
    public mutating func reset() {
        sent = [:]
    }

    private mutating func filter<T: Hashable>(_ values: [T], _ type: String, id: (T) -> UUID) -> [T] {
        filter(values, type, id: id, content: { $0 })
    }

    private mutating func filter<T, C: Hashable>(_ values: [T], _ type: String, id: (T) -> UUID,
                                                 content: (T) -> C) -> [T] {
        values.filter { value in
            let key = "\(type).\(id(value).uuidString)"
            let hash = content(value).hashValue
            guard sent[key] != hash else { return false }
            sent[key] = hash
            return true
        }
    }
}
