import Foundation
import ThymeCore

/// Files shared by the app and the monitor extension through the App Group container.
enum AppGroup {
    static let identifier = "group.com.danfoygel.screenthyme"
    static let cloudContainer = "iCloud.com.danfoygel.screenthyme"

    static let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
        ?? URL.applicationSupportDirectory.appending(path: "AppGroupFallback")

    /// Under Library/ because Xcode 27's devicectl only copies from there, and we pull journals off phones.
    static var container: URL {
        _ = migration
        return root.appending(path: "Library/ScreenThyme")
    }

    /// Runs once per process: moves files from the container root (builds before Xcode 27) into `container`,
    /// appending JSONL files that both places already have.
    private static let migration: Void = {
        let fileManager = FileManager.default
        let destination = root.appending(path: "Library/ScreenThyme")
        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let fd = open(destination.appending(path: ".migration.lock").path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        flock(fd, LOCK_EX)
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        func move(_ source: URL, to target: URL) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else { return }
            if !fileManager.fileExists(atPath: target.path) {
                try? fileManager.moveItem(at: source, to: target)
            } else if isDirectory.boolValue {
                for name in (try? fileManager.contentsOfDirectory(atPath: source.path)) ?? [] {
                    move(source.appending(path: name), to: target.appending(path: name))
                }
                try? fileManager.removeItem(at: source)
            } else {
                if source.pathExtension == "jsonl", let data = try? Data(contentsOf: source),
                   let handle = try? FileHandle(forWritingTo: target) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
                try? fileManager.removeItem(at: source)  // other files: the newer copy at `target` wins
            }
        }
        for name in ["Journal", "Rolling", "Outbox", "config.json", "monitor-config.json", "monitor-state.json"] {
            move(root.appending(path: name), to: destination.appending(path: name))
        }
        try? fileManager.removeItem(at: root.appending(path: "Locks"))
    }()

    static var journal: Journal { Journal(directory: container.appending(path: "Journal")) }

    static var configURL: URL { container.appending(path: "config.json") }
    static var monitorStateURL: URL { container.appending(path: "monitor-state.json") }
    /// Our own processes' energy use per day (`EnergyMeter`).
    static var energyLedgerURL: URL { container.appending(path: "energy.json") }
    /// Every app and website seen on this phone (written by `Sampler`).
    static var itemsURL: URL { container.appending(path: "items.json") }
    /// The rules this kid phone evaluates (`LocalRules`), written by the app and by `KidSync` in the extension.
    static var rulesURL: URL { container.appending(path: "rules.json") }
    /// What ScreenThyme enforces on this kid phone (`Policy`), written by the app and `KidSync`.
    static var policyURL: URL { container.appending(path: "policy.json") }
    /// How the pairing reports draw their codes (`TokenPairing.Display`), written by the app before it shows them.
    static var pairingDisplayURL: URL { container.appending(path: "token-pairing-display.json") }
    /// Today's limit fires and applied grants (`EnforcementDayState`), written by the `Enforcer`.
    static var enforcementStateURL: URL { container.appending(path: "enforcement-state.json") }
    /// The plan last applied (`AppliedPlan`), read by the block page to say why something is blocked.
    static var enforcementURL: URL { container.appending(path: "enforcement.json") }
    /// DeviceActivity registrations made by the `Enforcer`: activity name → signature.
    static var enforcementActivitiesURL: URL { container.appending(path: "enforcement-activities.json") }
    /// Encoded ApplicationTokens Downtime and limits never shield: ScreenThyme's own, from the app scan.
    static var exemptTokensURL: URL { container.appending(path: "exempt-tokens.json") }
    /// When the `Enforcer` emptied the overflow stores from before `ShieldBudget`, once per phone.
    static var retiredStoresClearedURL: URL { container.appending(path: "retired-stores-cleared.json") }
    /// `Sampler`'s last fetch of Apple's per-hour, per-app totals, to take differences from.
    static var snapshotURL: URL { container.appending(path: "sampler-snapshot.json") }
    /// Apps whose use is Safari's on their website (`WebMirror`): the `Sampler` adds to it, the `Enforcer` reads it.
    static var webMirrorURL: URL { container.appending(path: "web-mirror.json") }
    /// Which scanned items screenshot matching pairs (`TokenPairing.Mode`): the app sets it, the report extension draws by it.
    static var tokenPairingModeURL: URL { container.appending(path: "token-pairing-mode.json") }
    static func tokenPairingMode() -> TokenPairing.Mode { load(TokenPairing.Mode.self, from: tokenPairingModeURL) ?? .unmatched }
    /// The places the location test marked on this phone (`[Place]`), and what iOS said about where the phone is
    /// (PLAN.md §19): crossings of every fence and visits, uploaded for parents.
    static var placesURL: URL { container.appending(path: "Places/places.json") }
    static var placeEvents: JSONLinesFile<PlaceEvent> { JSONLinesFile(url: container.appending(path: "Places/events.jsonl")) }
    static var placeEventsLedger: JSONLinesFile<UUID> { JSONLinesFile(url: container.appending(path: "Places/events-uploaded.jsonl")) }
    /// The family's places, as parents named them (`FamilyPlaces`): `KidSync` fetches them, `PlaceWatcher` fences them.
    static var familyPlacesURL: URL { container.appending(path: "Places/family-places.json") }
    static func familyPlaces() -> FamilyPlaces? { load(FamilyPlaces.self, from: familyPlacesURL) }
    /// What the fence monitor said and believed, line by line (`PlaceWatcher.log`): no coordinates.
    static var placeDiagnosticsURL: URL { container.appending(path: "Places/diagnostics.txt") }

    /// Records waiting to be uploaded, and the ids already uploaded (uploads are idempotent).
    static var outbox: JSONLinesFile<AlertRecord> { JSONLinesFile(url: container.appending(path: "Outbox/alerts.jsonl")) }
    static var outboxLedger: JSONLinesFile<UUID> { JSONLinesFile(url: container.appending(path: "Outbox/uploaded.jsonl")) }
    static var samples: JSONLinesFile<UsageSample> { JSONLinesFile(url: container.appending(path: "Outbox/samples.jsonl")) }
    static var samplesLedger: JSONLinesFile<UUID> { JSONLinesFile(url: container.appending(path: "Outbox/samples-uploaded.jsonl")) }
    static var newItems: JSONLinesFile<TrackedItem> { JSONLinesFile(url: container.appending(path: "Outbox/items.jsonl")) }
    static var requests: JSONLinesFile<TimeRequest> { JSONLinesFile(url: container.appending(path: "Outbox/requests.jsonl")) }
    static var requestsLedger: JSONLinesFile<UUID> { JSONLinesFile(url: container.appending(path: "Outbox/requests-uploaded.jsonl")) }
    static var newItemsLedger: JSONLinesFile<UUID> { JSONLinesFile(url: container.appending(path: "Outbox/items-uploaded.jsonl")) }
    /// Every "one more minute" taken (`ExtraMinuteUse`), for the parents and the app's details.
    static var extraMinuteUses: JSONLinesFile<ExtraMinuteUse> { JSONLinesFile(url: container.appending(path: "Outbox/extra-minutes.jsonl")) }
    static var extraMinuteUsesLedger: JSONLinesFile<UUID> { JSONLinesFile(url: container.appending(path: "Outbox/extra-minutes-uploaded.jsonl")) }
    /// Every limit used up (`LimitReached`), for the day's timeline here and on parents' phones.
    static var limitsReached: JSONLinesFile<LimitReached> { JSONLinesFile(url: container.appending(path: "Outbox/limits-reached.jsonl")) }
    static var limitsReachedLedger: JSONLinesFile<UUID> { JSONLinesFile(url: container.appending(path: "Outbox/limits-reached-uploaded.jsonl")) }
    /// The kid's approvals of their own requests (`TimeGrant.isSelfApproved`), for the parents.
    static var selfGrants: JSONLinesFile<TimeGrant> { JSONLinesFile(url: container.appending(path: "Outbox/self-grants.jsonl")) }
    static var selfGrantsLedger: JSONLinesFile<UUID> { JSONLinesFile(url: container.appending(path: "Outbox/self-grants-uploaded.jsonl")) }
    /// Every answer this phone applied, a parent's or the kid's own; the enforcement state keeps only today's.
    static var grantHistory: JSONLinesFile<TimeGrant> { JSONLinesFile(url: container.appending(path: "grants.jsonl")) }

    static func loadRules() -> LocalRules? {
        guard let data = try? Data(contentsOf: rulesURL) else { return nil }
        return try? JSONDecoder.thyme.decode(LocalRules.self, from: data)
    }

    static func saveRules(_ rules: LocalRules) {
        try? JSONEncoder.thyme.encode(rules).write(to: rulesURL, options: .atomic)
    }

    /// The policy in force at `now`: temporary changes that ended are changed back (`Policy.current(at:)`). The file
    /// keeps them until the next fetch replaces it.
    static func loadPolicy(now: Date = Date()) -> Policy? { load(Policy.self, from: policyURL)?.current(at: now) }
    static func savePolicy(_ policy: Policy) { save(policy, to: policyURL) }

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.thyme.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) {
        try? JSONEncoder.thyme.encode(value).write(to: url, options: .atomic)
    }

    static func loadItems() -> [TrackedItem] {
        guard let data = try? Data(contentsOf: itemsURL) else { return [] }
        return (try? JSONDecoder.thyme.decode([TrackedItem].self, from: data)) ?? []
    }

    static func saveItems(_ items: [TrackedItem]) {
        try? JSONEncoder.thyme.encode(items).write(to: itemsURL, options: .atomic)
    }

    /// Serializes work across the app and extension processes (an exclusive `flock` on a file in the group).
    static func withLock<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let directory = container.appending(path: "Locks")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appending(path: name).path, O_RDWR | O_CREAT, 0o644)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer {
            if fd >= 0 {
                flock(fd, LOCK_UN)
                close(fd)
            }
        }
        return try body()
    }
}

/// Where this device reads and writes the family's records. The owner (Parent A) uses its private database;
/// everyone who accepted the share uses the shared database.
struct FamilyLocation: Codable, Sendable, Hashable {
    var zoneName: String
    var ownerName: String
    var isOwner: Bool
}

/// Written by the app, read by the extension on every wake.
/// A kid phone's copy of its rules, and when it last checked them against CloudKit.
struct LocalRules: Codable, Sendable {
    var rules: [Rule]
    var checkedAt: Date
    /// The `RuleSet` these came from: a parent phone nearby may send an older one than CloudKit's (PLAN.md §17).
    /// Nil for rules from before rule sets.
    var updatedAt: Date?
}

struct SharedConfig: Codable, Sendable {
    enum Role: String, Codable, Sendable { case unset, kid, parent }
    enum AuthMode: String, Codable, Sendable { case child, individual }

    var role: Role = .unset
    /// The kid this device captures for. In test mode it can be any kid (PLAN.md §7.1).
    var kid: Kid?
    var authMode: AuthMode = .child
    var testMode = false
    var family: FamilyLocation?
    /// What this parent's kids call them ("Dad"), shown on the kid's phone with their answers and pings.
    var parentName: String?
    /// Kid phones: how many minutes the block page's "One more minute" lets through (1–5, PLAN.md §15.5).
    /// Optional so configs written before it still load; nil is 1.
    var extraMinutes: Int?
    var epoch: LadderEpoch?
    /// Superseded by `AppGroup.loadRules()`; read only until a phone has written rules.json.
    var rules: [Rule] = []

    var extraMinuteLength: Int { ExtraMinute.minutes(extraMinutes) }

    /// The rules to evaluate on this kid phone.
    var currentRules: [Rule] { AppGroup.loadRules()?.rules ?? rules }

    static func load() -> SharedConfig {
        guard let data = try? Data(contentsOf: AppGroup.configURL),
              let config = try? JSONDecoder.thyme.decode(SharedConfig.self, from: data) else { return SharedConfig() }
        return config
    }

    func save() throws {
        try FileManager.default.createDirectory(at: AppGroup.container, withIntermediateDirectories: true)
        try JSONEncoder.thyme.encode(self).write(to: AppGroup.configURL, options: .atomic)
    }

    /// A day from this phone's own journal and samples.
    func dayInput(_ day: DayKey) -> DayInput {
        var input = DayInput(entries: AppGroup.journal.entries(on: day),
                             samples: AppGroup.samples.readAll().filter { $0.day == day }, dayStart: day.start())
        input.websites = Set(AppGroup.loadItems().filter { $0.kind == .domain }.map(\.id))
        return input
    }
}

enum MonitorStateStore {
    static func load(day: DayKey) -> MonitorDayState {
        guard let data = try? Data(contentsOf: AppGroup.monitorStateURL),
              let state = try? JSONDecoder.thyme.decode(MonitorDayState.self, from: data),
              state.day == day else { return MonitorDayState(day: day) }
        return state
    }

    static func save(_ state: MonitorDayState) {
        try? JSONEncoder.thyme.encode(state).write(to: AppGroup.monitorStateURL, options: .atomic)
    }
}
