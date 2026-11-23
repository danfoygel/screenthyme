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
    var policyChanges: [PolicyChange] = []
    var requests: [TimeRequest] = []
    var grants: [TimeGrant] = []
    var extraMinutes: [ExtraMinuteUse] = []
    var linkKeys: [LinkKey] = []
    var placeEvents: [PlaceEvent] = []
    var familyPlaces: [FamilyPlaces] = []
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
        case PolicyChange.recordType: PolicyChange.decode(record).map { policyChanges.append($0) }
        case TimeRequest.recordType: TimeRequest.decode(record).map { requests.append($0) }
        case TimeGrant.recordType: TimeGrant.decode(record).map { grants.append($0) }
        case ExtraMinuteUse.recordType: ExtraMinuteUse.decode(record).map { extraMinutes.append($0) }
        case LinkKey.recordType: LinkKey.decode(record).map { linkKeys.append($0) }
        case PlaceEvent.recordType: PlaceEvent.decode(record).map { placeEvents.append($0) }
        case FamilyPlaces.recordType: FamilyPlaces.decode(record).map { familyPlaces.append($0) }
        default: break
        }
    }

    /// Adds another batch's records after this one's.
    mutating func append(_ other: IngestBatch) {
        kids += other.kids
        items += other.items
        epochs += other.epochs
        fires += other.fires
        samples += other.samples
        heartbeats += other.heartbeats
        alerts += other.alerts
        rules += other.rules
        pings += other.pings
        energy += other.energy
        policies += other.policies
        policyChanges += other.policyChanges
        requests += other.requests
        grants += other.grants
        extraMinutes += other.extraMinutes
        linkKeys += other.linkKeys
        placeEvents += other.placeEvents
        familyPlaces += other.familyPlaces
        deletedRecordNames += other.deletedRecordNames
    }

    var isEmpty: Bool {
        kids.isEmpty && items.isEmpty && epochs.isEmpty && fires.isEmpty && samples.isEmpty && heartbeats.isEmpty
            && alerts.isEmpty
            && rules.isEmpty && pings.isEmpty && energy.isEmpty && policies.isEmpty && policyChanges.isEmpty && requests.isEmpty && grants.isEmpty
            && extraMinutes.isEmpty && linkKeys.isEmpty && placeEvents.isEmpty && familyPlaces.isEmpty
            && deletedRecordNames.isEmpty
    }
}

/// The local mirror of the family zone (PLAN.md §4.4). Fires are stored one file per kid per day and loaded lazily;
/// everything else is one small snapshot.
@MainActor @Observable
final class FamilyData {
    private struct Snapshot: Codable {
        /// Bump when stored types change: a snapshot of another version (or an unreadable one) triggers a full
        /// re-fetch, shown meanwhile.
        static let currentVersion = 7
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
        var policyChanges: [UUID: PolicyChange] = [:]
        var requests: [UUID: TimeRequest] = [:]
        var grants: [UUID: TimeGrant] = [:]
        var extraMinutes: [UUID: ExtraMinuteUse] = [:]
        var familyPlaces: FamilyPlaces?
        /// Where builds before link-key.json kept the nearby link's secret; read once, to move it.
        var linkKey: LinkKey?
        /// A full re-fetch under way (`isRebuilding`), kept so that a relaunch resumes it.
        var rebuild: Rebuild?

        struct Rebuild: Codable {
            /// Whether the change token was dropped yet; after that the re-fetch resumes from the token saved after
            /// each page.
            var started = false
            /// Kids, rules and pings the re-fetch has seen. A fetch from scratch reports no deletions, so those still
            /// unseen at its end were deleted.
            var seen: Set<UUID> = []
        }
    }

    private var snapshot = Snapshot()
    /// Bumped on every ingest so views that read fires through `fires(kid:day:)` re-render.
    private(set) var revision = 0
    @ObservationIgnored private let directory = URL.applicationSupportDirectory.appending(path: "FamilyData")
    @ObservationIgnored private lazy var fireStore = KidDayStore<UsageFire>(directory: directory.appending(path: "fires"))
    @ObservationIgnored private lazy var sampleStore = KidDayStore<UsageSample>(directory: directory.appending(path: "samples"))
    /// Where kids' phones were (PLAN.md §19), filed by the day each happened.
    @ObservationIgnored private lazy var placeEventStore = KidDayStore<PlaceEvent>(directory: directory.appending(path: "places"))

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
    /// Off on a kid's phone: where kids' phones were is for parents only (PLAN.md §19).
    @ObservationIgnored var keepsPlaceEvents = true
    /// The family's named places (PLAN.md §19).
    var places: [Place] { snapshot.familyPlaces?.places ?? [] }
    var familyPlaces: FamilyPlaces? { snapshot.familyPlaces }
    /// "One more minute" taken on kids' block pages.
    var extraMinutes: [UUID: ExtraMinuteUse] { snapshot.extraMinutes }
    /// The nearby link's secret (PLAN.md §17), in its own file: a build from a branch without the link rewrites the
    /// snapshot without the fields it doesn't know, which dropped it once. Fetched by name when missing
    /// (`LinkKeyService`).
    private(set) var linkKey: LinkKey?
    @ObservationIgnored private let linkKeyURL = URL.applicationSupportDirectory.appending(path: "link-key.json")

    /// The kid's policy in force now (temporary changes that ended changed back, as on the kid's phone), or an empty
    /// one to start editing. Apps the kid's phone gave new tokens are named by those (`Policy.followingNewTokens`), so
    /// a save stores them.
    func policy(for kid: UUID, now: Date = Date()) -> Policy {
        snapshot.policies[kid]?.current(at: now).followingNewTokens(items: snapshot.items) ?? Policy(kidID: kid)
    }

    /// As saved: with temporary changes that ended, until the next save drops them.
    func storedPolicy(for kid: UUID) -> Policy? {
        snapshot.policies[kid]
    }

    /// The kid's policy as it was at `date`, from the change history; nil before the first.
    func storedPolicy(for kid: UUID, at date: Date) -> Policy? {
        PolicyChange.policy(at: date, changes: snapshot.policyChanges.values.filter { $0.kidID == kid },
                            current: storedPolicy(for: kid))
    }

    /// Saved policies, temporary changes changing back (those still to come too) and answered requests for more time,
    /// oldest first.
    func policyHistory(for kid: UUID) -> [PolicyHistoryEntry] {
        let saves = snapshot.policyChanges.values.filter { $0.kidID == kid }
        let changes = saves.map(PolicyHistoryEntry.change)
        let reverts = PolicyRevert.all(changes: Array(saves), current: storedPolicy(for: kid)).map(PolicyHistoryEntry.revert)
        let grants = snapshot.grants.values.filter { $0.kidID == kid }.map(PolicyHistoryEntry.grant)
        return (changes + reverts + grants).sorted { ($0.at, $0.id.uuidString) < ($1.at, $1.id.uuidString) }
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

    /// A full re-fetch of the family zone is under way: kids, policies and rules may be missing or out of date until
    /// it ends, so nothing a parent saves may be built from them.
    var isRebuilding: Bool { snapshot.rebuild != nil }

    /// The re-fetch hasn't started: drop the change token, then call `rebuildStarted()`.
    var rebuildNeedsReset: Bool { snapshot.rebuild?.started == false }

    init() {
        linkKey = (try? Data(contentsOf: linkKeyURL)).flatMap { try? JSONDecoder.thyme.decode(LinkKey.self, from: $0) }
        guard let data = try? Data(contentsOf: directory.appending(path: "snapshot.json")) else { return }
        let saved = try? JSONDecoder.thyme.decode(Snapshot.self, from: data)
        if let saved { snapshot = saved }
        if saved?.version != Snapshot.currentVersion {
            // Another build's snapshot (or an unreadable one) can lack records or fields that build didn't know:
            // fetch everything again, showing what it has meanwhile. Emptying it hid kids and their limits for hours
            // while the re-fetch ran, and a policy saved from that empty mirror would have replaced the kid's.
            snapshot.version = Snapshot.currentVersion
            snapshot.rebuild = Snapshot.Rebuild()
        }
        if linkKey == nil, let key = snapshot.linkKey { saveLinkKey(key) }
    }

    func rebuildStarted() {
        snapshot.rebuild?.started = true
        saveSnapshot()
    }

    /// One page of the re-fetch, kept as it arrives so an interrupted re-fetch loses none of it.
    func ingestRebuildPage(_ batch: IngestBatch) {
        snapshot.rebuild?.seen.formUnion(batch.kids.map(\.id) + batch.rules.map(\.id) + batch.pings.map(\.id))
        ingest(batch)
    }

    /// The re-fetch reached the end of the zone: drops the kids, rules and pings it didn't see.
    func rebuildDone() {
        guard let seen = snapshot.rebuild?.seen else { return }
        snapshot.kids = snapshot.kids.filter { seen.contains($0.key) }
        snapshot.rules = snapshot.rules.filter { seen.contains($0.key) }
        snapshot.pings = snapshot.pings.filter { seen.contains($0.key) }
        snapshot.rebuild = nil
        saveSnapshot()
        revision += 1
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
        for change in batch.policyChanges { snapshot.policyChanges[change.id] = change }
        for request in batch.requests { snapshot.requests[request.id] = request }
        for grant in batch.grants { snapshot.grants[grant.requestID] = grant }
        for use in batch.extraMinutes { snapshot.extraMinutes[use.id] = use }
        if let key = batch.linkKeys.last, key != linkKey { saveLinkKey(key) }
        for places in batch.familyPlaces where places.updatedAt >= (snapshot.familyPlaces?.updatedAt ?? .distantPast) {
            snapshot.familyPlaces = places
        }
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
        for (key, events) in Dictionary(grouping: batch.placeEvents.filter { keepsPlaceEvents && $0.kidID != nil },
                                        by: { KidDay(kid: $0.kidID!, day: $0.day) }) {
            placeEventStore.merge(events, into: key)
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

    /// What the kid's phone said about where it was, on the days `first` through `last`, oldest first.
    func placeEvents(kid: UUID, from first: DayKey, through last: DayKey) -> [PlaceEvent] {
        _ = revision
        var events: [PlaceEvent] = []
        var day = first
        while day <= last {
            events += placeEventStore.values(KidDay(kid: kid, day: day))
            day = day.adding(days: 1)
        }
        return events.sorted { ($0.at, $0.observedAt) < ($1.at, $1.observedAt) }
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
        snapshot.policyChanges = snapshot.policyChanges.filter { $0.value.kidID != kid }
        snapshot.requests = snapshot.requests.filter { $0.value.kidID != kid }
        snapshot.grants = snapshot.grants.filter { $0.value.kidID != kid }
        snapshot.extraMinutes = snapshot.extraMinutes.filter { $0.value.kidID != kid }
        snapshot.lastFireAt[kid] = nil
        fireStore.forget(kid: kid)
        sampleStore.forget(kid: kid)
        placeEventStore.forget(kid: kid)
        saveSnapshot()
        revision += 1
    }

    // MARK: - Files

    private func saveLinkKey(_ key: LinkKey) {
        linkKey = key
        try? JSONEncoder.thyme.encode(key)
            .write(to: linkKeyURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func saveSnapshot() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder.thyme.encode(snapshot).write(to: directory.appending(path: "snapshot.json"), options: .atomic)
    }
}

/// One line of a kid's change history: a parent's save of the policy, a temporary one changing back, or a parent's
/// answer to a request for more time.
enum PolicyHistoryEntry: Identifiable {
    case change(PolicyChange)
    case revert(PolicyRevert)
    case grant(TimeGrant)

    var id: UUID {
        switch self {
        case let .change(change): change.id
        case let .revert(revert): revert.id
        case let .grant(grant): grant.requestID
        }
    }

    var at: Date {
        switch self {
        case let .change(change): change.at
        case let .revert(revert): revert.at
        case let .grant(grant): grant.at
        }
    }

    var by: String {
        switch self {
        case let .change(change): change.by
        case let .revert(revert): revert.change.by
        case let .grant(grant): grant.by
        }
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
