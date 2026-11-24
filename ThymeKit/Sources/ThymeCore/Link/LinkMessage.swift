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
/// usage, heartbeat, alerts, requests for more time (and its own approvals of them) and one more minute; a parent phone
/// sends that kid's rules, policy and answers.
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
    /// Matching by a parent's camera (PLAN.md §15.6), sent at once rather than every 15 s, and never filtered. Optional,
    /// so a bundle from a build without it still opens.
    public var pairing: [LinkPairing]?
    /// Optional, so a bundle from a build without it still opens.
    public var extraMinutes: [ExtraMinuteUse]?
    /// Optional, so a bundle from a build without it still opens.
    public var limitsReached: [LimitReached]?
    /// Parent controls (`ParentUnlock`), like `pairing`. Optional, so a bundle from a build without it still opens.
    public var unlock: [LinkUnlock]?
    /// Screens to open on the kid's phone, like `pairing`. A field of its own, not a new `LinkPairing` case: a build
    /// that can't decode a bundle closes the connection, and one without this field ignores it.
    public var open: [LinkOpen]?

    public init() {}

    public var isEmpty: Bool { count == 0 }

    public var count: Int {
        kids.count + items.count + epochs.count + fires.count + samples.count + heartbeats.count + alerts.count
            + requests.count + ruleSets.count + policies.count + grants.count + (pairing?.count ?? 0)
            + (extraMinutes?.count ?? 0) + (limitsReached?.count ?? 0) + (unlock?.count ?? 0) + (open?.count ?? 0)
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
        copy.extraMinutes = extraMinutes?.filter { $0.kidID == kid }
        copy.limitsReached = limitsReached?.filter { $0.kidID == kid }
        return copy
    }
}

/// Matching scanned apps with a parent's camera (PLAN.md §15.6): the kid's phone shows one pairing report at a time,
/// the parent's camera reads its codes, and the parent's phone sends them back, which moves the kid's phone on to the
/// next report. The kid's phone pairs, as it does from screenshots.
public enum LinkPairing: Codable, Sendable, Hashable {
    /// Kid → parent: the pairing screen is open (or closed: `showing` nil) and shows that report, `done` of `total`
    /// read.
    case progress(showing: String?, done: Int, total: Int)
    /// Parent → kid: the codes of every report the camera has read all of, as their texts.
    case codes([String])
    /// Kid → parent: what pairing found, for the parent's screen.
    case result(String)
}

/// Parent → kid: open the kid phone's side of what the parent just started on theirs.
public enum LinkOpen: Codable, Sendable, Hashable {
    /// The parent opened the camera to match apps (PLAN.md §15.6): show the pairing reports.
    case cameraPairing
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
        out.pairing = bundle.pairing
        out.unlock = bundle.unlock
        out.open = bundle.open
        out.extraMinutes = bundle.extraMinutes.map { filter($0, "ExtraMinuteUse", id: \.id) }
        out.limitsReached = bundle.limitsReached.map { filter($0, "LimitReached", id: \.id) }
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
