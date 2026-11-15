import Foundation
import ThymeCore

/// Files shared by the app and the monitor extension through the App Group container.
enum AppGroup {
    static let identifier = "group.com.danfoygel.screenthyme"
    static let cloudContainer = "iCloud.com.danfoygel.screenthyme"

    static var container: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
            ?? URL.applicationSupportDirectory.appending(path: "AppGroupFallback")
    }

    static var journal: Journal { Journal(directory: container.appending(path: "Journal")) }

    static var configURL: URL { container.appending(path: "config.json") }
    /// The same config without token data (~500 KB for a full scan), read by the extension on every fire.
    static var monitorConfigURL: URL { container.appending(path: "monitor-config.json") }
    static var monitorStateURL: URL { container.appending(path: "monitor-state.json") }
    static var outbox: JSONLinesFile<AlertRecord> { JSONLinesFile(url: container.appending(path: "Outbox/alerts.jsonl")) }
    static var outboxLedger: JSONLinesFile<UUID> { JSONLinesFile(url: container.appending(path: "Outbox/uploaded.jsonl")) }
}

/// Where this device reads and writes the family's records. The owner (Parent A) uses its private database;
/// everyone who accepted the share uses the shared database.
struct FamilyLocation: Codable, Sendable, Hashable {
    var zoneName: String
    var ownerName: String
    var isOwner: Bool
}

/// Written by the app, read by the extension on every fire. Small: items carry tokens, ~100 of them.
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
    var items: [TrackedItem] = []
    var rules: [Rule] = []
    /// S1(b): the per-activity event cap is undocumented; adjustable from the debug screen.
    var maxEventsPerActivity = 1000

    static func load() -> SharedConfig {
        load(from: AppGroup.configURL)
    }

    /// For the extension: no tokens, so it stays well inside the extension's memory limit.
    /// Today's (or any day's) journal as reconstruction input, with this scan's ladders.
    func dayInput(_ day: DayKey) -> DayInput {
        DayInput(entries: AppGroup.journal.entries(on: day), dayStart: day.start(),
                 spec: epoch?.spec ?? .standard,
                 shortItems: Set(items.filter { $0.kind == .domain }.map(\.id)),
                 totalsOnlyItems: Set(items.filter { $0.kind != .app }.map(\.id)))
    }

    static func loadForMonitor() -> SharedConfig {
        FileManager.default.fileExists(atPath: AppGroup.monitorConfigURL.path)
            ? load(from: AppGroup.monitorConfigURL) : load()
    }

    private static func load(from url: URL) -> SharedConfig {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder.thyme.decode(SharedConfig.self, from: data) else { return SharedConfig() }
        return config
    }

    func save() throws {
        try FileManager.default.createDirectory(at: AppGroup.container, withIntermediateDirectories: true)
        try JSONEncoder.thyme.encode(self).write(to: AppGroup.configURL, options: .atomic)
        var slim = self
        for index in slim.items.indices { slim.items[index].tokenData = nil }
        try JSONEncoder.thyme.encode(slim).write(to: AppGroup.monitorConfigURL, options: .atomic)
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
