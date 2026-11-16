import CloudKit
import Foundation

/// Records a parent phone saved without the internet, kept and retried on every refresh (PLAN.md §17). An answer given
/// to a kid nearby, offline, must still reach CloudKit: for the other parent, and for the kid's phone, which looks for
/// its answer there until it has one.
enum PendingSaves {
    private static let url = URL.applicationSupportDirectory.appending(path: "pending-saves.data")

    /// Saves now, or keeps the records for later when there's no network. Other errors are thrown as before.
    static func save(_ records: [CKRecord], to store: CloudStore) async throws {
        do {
            try await store.save(records: records)
        } catch let error as CKError where error.isOffline {
            keep(records)
        }
    }

    static func save<T: CloudRecordable>(_ values: [T], to store: CloudStore) async throws {
        try await save(values.map { try $0.record(in: store.zoneID) }, to: store)
    }

    static var count: Int { load().count }

    /// Sends what's kept; keeps it again if still offline.
    static func retry(store: CloudStore) async {
        let records = load()
        guard !records.isEmpty else { return }
        try? FileManager.default.removeItem(at: url)
        do {
            try await save(records, to: store)
        } catch {
            // Rejected for good (e.g. the family changed): nothing to retry.
        }
    }

    /// Later saves of a record replace earlier ones.
    private static func keep(_ records: [CKRecord]) {
        var kept = Dictionary(load().map { ($0.recordID, $0) }, uniquingKeysWith: { _, new in new })
        for record in records { kept[record.recordID] = record }
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: Array(kept.values), requiringSecureCoding: true)
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func load() -> [CKRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? NSKeyedUnarchiver.unarchivedArrayOfObjects(ofClass: CKRecord.self, from: data)) ?? []
    }
}

extension CKError {
    /// No network (or iCloud busy): worth retrying later, not worth an alert.
    var isOffline: Bool {
        [.networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy].contains(code)
    }
}
