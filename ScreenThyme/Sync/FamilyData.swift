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
    var heartbeats: [Heartbeat] = []
    var alerts: [AlertRecord] = []
    var rules: [Rule] = []
    var pings: [Ping] = []
    var deletedRecordNames: [String] = []

    mutating func add(_ record: CKRecord) {
        switch record.recordType {
        case Kid.recordType: Kid.decode(record).map { kids.append($0) }
        case TrackedItem.recordType: TrackedItem.decode(record).map { items.append($0) }
        case LadderEpoch.recordType: LadderEpoch.decode(record).map { epochs.append($0) }
        case UsageFire.recordType: UsageFire.decode(record).map { fires.append($0) }
        case Heartbeat.recordType: Heartbeat.decode(record).map { heartbeats.append($0) }
        case AlertRecord.recordType: AlertRecord.decode(record).map { alerts.append($0) }
        case Rule.recordType: Rule.decode(record).map { rules.append($0) }
        case Ping.recordType: Ping.decode(record).map { pings.append($0) }
        default: break
        }
    }

    var isEmpty: Bool {
        kids.isEmpty && items.isEmpty && epochs.isEmpty && fires.isEmpty && heartbeats.isEmpty && alerts.isEmpty
            && rules.isEmpty && pings.isEmpty && deletedRecordNames.isEmpty
    }
}

/// The local mirror of the family zone (PLAN.md §4.4). Fires are stored one file per kid per day and loaded lazily;
/// everything else is one small snapshot.
@MainActor @Observable
final class FamilyData {
    private struct Snapshot: Codable {
        var kids: [UUID: Kid] = [:]
        var items: [UUID: TrackedItem] = [:]
        var epochs: [UUID: LadderEpoch] = [:]
        var rules: [UUID: Rule] = [:]
        var alerts: [UUID: AlertRecord] = [:]
        var heartbeats: [UUID: Heartbeat] = [:]
        var lastFireAt: [UUID: Date] = [:]
        var pings: [UUID: Ping] = [:]
    }

    private var snapshot = Snapshot()
    /// Bumped on every ingest so views that read fires through `fires(kid:day:)` re-render.
    private(set) var revision = 0
    @ObservationIgnored private var fireCache: [UUID: [DayKey: [UUID: UsageFire]]] = [:]
    @ObservationIgnored private let directory = URL.applicationSupportDirectory.appending(path: "FamilyData")

    var kids: [UUID: Kid] { snapshot.kids }
    var items: [UUID: TrackedItem] { snapshot.items }
    var epochs: [UUID: LadderEpoch] { snapshot.epochs }
    var rules: [UUID: Rule] { snapshot.rules }
    var alerts: [UUID: AlertRecord] { snapshot.alerts }
    var heartbeats: [UUID: Heartbeat] { snapshot.heartbeats }
    var lastFireAt: [UUID: Date] { snapshot.lastFireAt }
    var pings: [UUID: Ping] { snapshot.pings }

    var sortedKids: [Kid] {
        snapshot.kids.values.sorted { ($0.isTest ? 1 : 0, $0.displayName) < ($1.isTest ? 1 : 0, $1.displayName) }
    }

    init() {
        if let data = try? Data(contentsOf: directory.appending(path: "snapshot.json")),
           let saved = try? JSONDecoder.thyme.decode(Snapshot.self, from: data) {
            snapshot = saved
        }
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

        let byKidDay = Dictionary(grouping: batch.fires) { KidDay(kid: $0.kidID, day: $0.day) }
        for (key, fires) in byKidDay {
            var stored = loadFires(key)
            for fire in fires { stored[fire.id] = fire }
            fireCache[key.kid, default: [:]][key.day] = stored
            saveFires(key, stored)
            if let latest = fires.map(\.firedAt).max(), latest > (snapshot.lastFireAt[key.kid] ?? .distantPast) {
                snapshot.lastFireAt[key.kid] = latest
            }
        }
        saveSnapshot()
        revision += 1
        return newAlerts
    }

    func fires(kid: UUID, day: DayKey) -> [UsageFire] {
        _ = revision
        let key = KidDay(kid: kid, day: day)
        if let cached = fireCache[kid]?[day] { return Array(cached.values) }
        let loaded = loadFires(key)
        fireCache[kid, default: [:]][day] = loaded
        return Array(loaded.values)
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
        snapshot.lastFireAt[kid] = nil
        fireCache[kid] = nil
        try? FileManager.default.removeItem(at: directory.appending(path: "fires/\(kid.uuidString)"))
        saveSnapshot()
        revision += 1
    }

    // MARK: - Files

    private struct KidDay: Hashable {
        var kid: UUID
        var day: DayKey
    }

    private func firesURL(_ key: KidDay) -> URL {
        directory.appending(path: "fires/\(key.kid.uuidString)/\(key.day).json")
    }

    private func loadFires(_ key: KidDay) -> [UUID: UsageFire] {
        if let cached = fireCache[key.kid]?[key.day] { return cached }
        guard let data = try? Data(contentsOf: firesURL(key)),
              let fires = try? JSONDecoder.thyme.decode([UsageFire].self, from: data) else { return [:] }
        return Dictionary(fires.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func saveFires(_ key: KidDay, _ fires: [UUID: UsageFire]) {
        let url = firesURL(key)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder.thyme.encode(Array(fires.values)).write(to: url, options: .atomic)
    }

    private func saveSnapshot() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder.thyme.encode(snapshot).write(to: directory.appending(path: "snapshot.json"), options: .atomic)
    }
}
