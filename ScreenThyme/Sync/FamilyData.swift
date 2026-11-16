import CloudKit
import Foundation
import Observation
import ThymeCore

/// Records decoded from one fetch (or produced locally by the replay tool).
struct IngestBatch: Sendable {
    var kids: [Kid] = []
    var items: [TrackedItem] = []
    var epochs: [LadderEpoch] = []
    var fires: [UsageFire] = []
    var samples: [UsageSample] = []
    var heartbeats: [Heartbeat] = []
    var alerts: [AlertRecord] = []
    var rules: [Rule] = []
    var pings: [Ping] = []
    var energy: [EnergyReport] = []
    var policies: [Policy] = []
    var requests: [TimeRequest] = []
    var grants: [TimeGrant] = []
    var linkKeys: [LinkKey] = []
    var deletedRecordNames: [String] = []

    mutating func add(_ record: CKRecord) {
        switch record.recordType {
        case Kid.recordType: Kid.decode(record).map { kids.append($0) }
        case TrackedItem.recordType: TrackedItem.decode(record).map { items.append($0) }
        case LadderEpoch.recordType: LadderEpoch.decode(record).map { epochs.append($0) }
        case UsageFire.recordType: UsageFire.decode(record).map { fires.append($0) }
        case UsageSample.recordType: UsageSample.decode(record).map { samples.append($0) }
        case Heartbeat.recordType: Heartbeat.decode(record).map { heartbeats.append($0) }
        case AlertRecord.recordType: AlertRecord.decode(record).map { alerts.append($0) }
        case Rule.recordType: Rule.decode(record).map { rules.append($0) }
        case Ping.recordType: Ping.decode(record).map { pings.append($0) }
        case EnergyReport.recordType: EnergyReport.decode(record).map { energy.append($0) }
        case Policy.recordType: Policy.decode(record).map { policies.append($0) }
        case TimeRequest.recordType: TimeRequest.decode(record).map { requests.append($0) }
        case TimeGrant.recordType: TimeGrant.decode(record).map { grants.append($0) }
        case LinkKey.recordType: LinkKey.decode(record).map { linkKeys.append($0) }
        default: break
        }
    }

    var isEmpty: Bool {
        kids.isEmpty && items.isEmpty && epochs.isEmpty && fires.isEmpty && samples.isEmpty && heartbeats.isEmpty
            && alerts.isEmpty
            && rules.isEmpty && pings.isEmpty && energy.isEmpty && policies.isEmpty && requests.isEmpty && grants.isEmpty
            && linkKeys.isEmpty && deletedRecordNames.isEmpty
    }
}

/// The local mirror of the family zone (PLAN.md §4.4). Fires are stored one file per kid per day and loaded lazily;
/// everything else is one small snapshot.
@MainActor @Observable
final class FamilyData {
    private struct Snapshot: Codable {
        /// Bump when stored types change: an older (or unreadable) snapshot triggers a full re-fetch.
        static let currentVersion = 3
        var version = currentVersion
        var kids: [UUID: Kid] = [:]
        var items: [UUID: TrackedItem] = [:]
        var epochs: [UUID: LadderEpoch] = [:]
        var rules: [UUID: Rule] = [:]
        var alerts: [UUID: AlertRecord] = [:]
        var heartbeats: [UUID: Heartbeat] = [:]
        var lastFireAt: [UUID: Date] = [:]
        var pings: [UUID: Ping] = [:]
        var energy: [UUID: EnergyReport] = [:]
        var policies: [UUID: Policy] = [:]
        var requests: [UUID: TimeRequest] = [:]
        var grants: [UUID: TimeGrant] = [:]
        /// Missing from older snapshots; fetched by name when it is (`LinkKeyService`).
        var linkKey: LinkKey?
    }

    private var snapshot = Snapshot()
    /// Bumped on every ingest so views that read fires through `fires(kid:day:)` re-render.
    private(set) var revision = 0
    @ObservationIgnored private let directory = URL.applicationSupportDirectory.appending(path: "FamilyData")
    @ObservationIgnored private lazy var fireStore = KidDayStore<UsageFire>(directory: directory.appending(path: "fires"))
    @ObservationIgnored private lazy var sampleStore = KidDayStore<UsageSample>(directory: directory.appending(path: "samples"))

    var kids: [UUID: Kid] { snapshot.kids }
    var items: [UUID: TrackedItem] { snapshot.items }
    var epochs: [UUID: LadderEpoch] { snapshot.epochs }
    var rules: [UUID: Rule] { snapshot.rules }
    var alerts: [UUID: AlertRecord] { snapshot.alerts }
    var heartbeats: [UUID: Heartbeat] { snapshot.heartbeats }
    var lastFireAt: [UUID: Date] { snapshot.lastFireAt }
    var pings: [UUID: Ping] { snapshot.pings }
    var requests: [UUID: TimeRequest] { snapshot.requests }
    var grants: [UUID: TimeGrant] { snapshot.grants }
    var linkKey: LinkKey? { snapshot.linkKey }

    /// The kid's policy, or an empty one to start editing.
    func policy(for kid: UUID) -> Policy {
        snapshot.policies[kid] ?? Policy(kidID: kid)
    }

    func storedPolicy(for kid: UUID) -> Policy? {
        snapshot.policies[kid]
    }

    /// Requests no parent has answered yet, newest first.
    var openRequests: [TimeRequest] {
        snapshot.requests.values.filter { snapshot.grants[$0.id] == nil }.sorted { $0.at > $1.at }
    }

    /// Newest day first.
    func energyReports(for kid: UUID) -> [EnergyReport] {
        snapshot.energy.values.filter { $0.kidID == kid }.sorted { $0.day > $1.day }
    }

    var sortedKids: [Kid] {
        snapshot.kids.values.sorted { ($0.isTest ? 1 : 0, $0.displayName) < ($1.isTest ? 1 : 0, $1.displayName) }
    }

    /// The snapshot couldn't be used, so records fetched before it was written are missing here: the next refresh
    /// must ignore its change token and fetch everything.
    @ObservationIgnored private(set) var needsFullFetch = false

    init() {
        guard let data = try? Data(contentsOf: directory.appending(path: "snapshot.json")) else { return }
        if let saved = try? JSONDecoder.thyme.decode(Snapshot.self, from: data), saved.version == Snapshot.currentVersion {
            snapshot = saved
        } else {
            needsFullFetch = true
        }
    }

    func fullFetchDone() {
        needsFullFetch = false
        saveSnapshot()
    }

    /// Returns alerts that weren't known before, for local notifications.
    @discardableResult
    func ingest(_ batch: IngestBatch) -> [AlertRecord] {
        guard !batch.isEmpty else { return [] }
        for kid in batch.kids { snapshot.kids[kid.id] = kid }
        for item in batch.items { snapshot.items[item.id] = item }
        for epoch in batch.epochs { snapshot.epochs[epoch.id] = epoch }
        for rule in batch.rules { snapshot.rules[rule.id] = rule }
        for ping in batch.pings { snapshot.pings[ping.id] = ping }
        for report in batch.energy where report.updatedAt >= (snapshot.energy[report.id]?.updatedAt ?? .distantPast) {
            snapshot.energy[report.id] = report
        }
        for policy in batch.policies where policy.updatedAt >= (snapshot.policies[policy.kidID]?.updatedAt ?? .distantPast) {
            snapshot.policies[policy.kidID] = policy
        }
        for request in batch.requests { snapshot.requests[request.id] = request }
        for grant in batch.grants { snapshot.grants[grant.requestID] = grant }
        if let key = batch.linkKeys.last { snapshot.linkKey = key }
        for heartbeat in batch.heartbeats where heartbeat.at > (snapshot.heartbeats[heartbeat.kidID]?.at ?? .distantPast) {
            snapshot.heartbeats[heartbeat.kidID] = heartbeat
        }
        let newAlerts = batch.alerts.filter { snapshot.alerts[$0.id] == nil }
        for alert in batch.alerts { snapshot.alerts[alert.id] = alert }

        for name in batch.deletedRecordNames {
            let parts = name.split(separator: ".", maxSplits: 1)
            guard parts.count == 2, let id = UUID(uuidString: String(parts[1])) else { continue }
            switch String(parts[0]) {
            case Rule.recordType: snapshot.rules[id] = nil
            case Ping.recordType: snapshot.pings[id] = nil
            case Kid.recordType: snapshot.kids[id] = nil
            default: break
            }
        }

        for (key, fires) in Dictionary(grouping: batch.fires, by: { KidDay(kid: $0.kidID, day: $0.day) }) {
            fireStore.merge(fires, into: key)
            if let latest = fires.map(\.firedAt).max(), latest > (snapshot.lastFireAt[key.kid] ?? .distantPast) {
                snapshot.lastFireAt[key.kid] = latest
            }
        }
        for (key, samples) in Dictionary(grouping: batch.samples, by: { KidDay(kid: $0.kidID, day: $0.day) }) {
            sampleStore.merge(samples, into: key)
        }
        saveSnapshot()
        revision += 1
        return newAlerts
    }

    func fires(kid: UUID, day: DayKey) -> [UsageFire] {
        _ = revision
        return fireStore.values(KidDay(kid: kid, day: day))
    }

    func samples(kid: UUID, day: DayKey) -> [UsageSample] {
        _ = revision
        return sampleStore.values(KidDay(kid: kid, day: day))
    }

    func items(for kid: UUID) -> [UUID: TrackedItem] {
        snapshot.items.filter { $0.value.kidID == kid }
    }

    func rules(for kid: UUID) -> [Rule] {
        snapshot.rules.values.filter { $0.kidID == kid }.sorted { $0.condition.summary < $1.condition.summary }
    }

    /// Removes a kid and everything recorded for it from this device (test kids from the replay tool).
    func forget(kid: UUID) {
        snapshot.kids[kid] = nil
        snapshot.items = snapshot.items.filter { $0.value.kidID != kid }
        snapshot.rules = snapshot.rules.filter { $0.value.kidID != kid }
        snapshot.alerts = snapshot.alerts.filter { $0.value.kidID != kid }
        snapshot.heartbeats[kid] = nil
        snapshot.energy = snapshot.energy.filter { $0.value.kidID != kid }
        snapshot.policies[kid] = nil
        snapshot.requests = snapshot.requests.filter { $0.value.kidID != kid }
        snapshot.grants = snapshot.grants.filter { $0.value.kidID != kid }
        snapshot.lastFireAt[kid] = nil
        fireStore.forget(kid: kid)
        sampleStore.forget(kid: kid)
        saveSnapshot()
        revision += 1
    }

    // MARK: - Files

    private func saveSnapshot() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder.thyme.encode(snapshot).write(to: directory.appending(path: "snapshot.json"), options: .atomic)
    }
}

private struct KidDay: Hashable {
    var kid: UUID
    var day: DayKey
}

/// Records kept one JSON file per kid per day, loaded lazily and cached.
private final class KidDayStore<Value: Codable & Identifiable> where Value.ID == UUID {
    private let directory: URL
    private var cache: [KidDay: [UUID: Value]] = [:]

    init(directory: URL) {
        self.directory = directory
    }

    func values(_ key: KidDay) -> [Value] {
        Array(load(key).values)
    }

    func merge(_ values: [Value], into key: KidDay) {
        var stored = load(key)
        for value in values { stored[value.id] = value }
        cache[key] = stored
        let url = self.url(key)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder.thyme.encode(Array(stored.values)).write(to: url, options: .atomic)
    }

    func forget(kid: UUID) {
        cache = cache.filter { $0.key.kid != kid }
        try? FileManager.default.removeItem(at: directory.appending(path: kid.uuidString))
    }

    private func load(_ key: KidDay) -> [UUID: Value] {
        if let cached = cache[key] { return cached }
        let values = (try? Data(contentsOf: url(key))).flatMap { try? JSONDecoder.thyme.decode([Value].self, from: $0) } ?? []
        let loaded = Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        cache[key] = loaded
        return loaded
    }

    private func url(_ key: KidDay) -> URL {
        directory.appending(path: "\(key.kid.uuidString)/\(key.day).json")
    }
}
