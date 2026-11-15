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
    /// Today's limit fires and applied grants (`EnforcementDayState`), written by the `Enforcer`.
    static var enforcementStateURL: URL { container.appending(path: "enforcement-state.json") }
    /// The plan last applied (`AppliedPlan`), read by the block page to say why something is blocked.
    static var enforcementURL: URL { container.appending(path: "enforcement.json") }
    /// DeviceActivity registrations made by the `Enforcer`: activity name → signature.
    static var enforcementActivitiesURL: URL { container.appending(path: "enforcement-activities.json") }
    /// `Sampler`'s last fetch of Apple's per-hour, per-app totals, to take differences from.
    static var snapshotURL: URL { container.appending(path: "sampler-snapshot.json") }

    /// Records waiting to be uploaded, and the ids already uploaded (uploads are idempotent).
    static var outbox: JSONLinesFile<AlertRecord> { JSONLinesFile(url: container.appending(path: "Outbox/alerts.jsonl")) }
    static var outboxLedger: JSONLinesFile<UUID> { JSONLinesFile(url: container.appending(path: "Outbox/uploaded.jsonl")) }
    static var samples: JSONLinesFile<UsageSample> { JSONLinesFile(url: container.appending(path: "Outbox/samples.jsonl")) }
    static var samplesLedger: JSONLinesFile<UUID> { JSONLinesFile(url: container.appending(path: "Outbox/samples-uploaded.jsonl")) }
    static var newItems: JSONLinesFile<TrackedItem> { JSONLinesFile(url: container.appending(path: "Outbox/items.jsonl")) }
    static var requests: JSONLinesFile<TimeRequest> { JSONLinesFile(url: container.appending(path: "Outbox/requests.jsonl")) }
    static var requestsLedger: JSONLinesFile<UUID> { JSONLinesFile(url: container.appending(path: "Outbox/requests-uploaded.jsonl")) }
    static var newItemsLedger: JSONLinesFile<UUID> { JSONLinesFile(url: container.appending(path: "Outbox/items-uploaded.jsonl")) }

    static func loadRules() -> LocalRules? {
        guard let data = try? Data(contentsOf: rulesURL) else { return nil }
        return try? JSONDecoder.thyme.decode(LocalRules.self, from: data)
    }

    static func saveRules(_ rules: LocalRules) {
        try? JSONEncoder.thyme.encode(rules).write(to: rulesURL, options: .atomic)
    }

    static func loadPolicy() -> Policy? { load(Policy.self, from: policyURL) }
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
    var epoch: LadderEpoch?
    /// Superseded by `AppGroup.loadRules()`; read only until a phone has written rules.json.
    var rules: [Rule] = []

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
        DayInput(entries: AppGroup.journal.entries(on: day),
                 samples: AppGroup.samples.readAll().filter { $0.day == day }, dayStart: day.start())
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
