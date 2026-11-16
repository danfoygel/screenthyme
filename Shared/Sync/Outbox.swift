import Foundation
import ThymeCore

/// Uploads App Group outbox files, which the ledger files track. Compiled into the app, the monitor extension and the
/// block page's button extension.
enum Outbox {
    /// Requests for more time and alerts, right away: during Downtime nothing else on the kid's phone may run to send
    /// them (PLAN.md §15.2).
    static func sendRequests(config: SharedConfig) async throws {
        guard let family = config.family else { return }
        let store = CloudStore(family: family)
        _ = try await send(AppGroup.requests, ledger: AppGroup.requestsLedger, to: store)
        _ = try await send(AppGroup.outbox, ledger: AppGroup.outboxLedger, to: store)
    }

    /// Uploads what the ledger doesn't list yet, then records it there.
    static func send<T: CloudRecordable & Identifiable>(_ file: JSONLinesFile<T>, ledger: JSONLinesFile<UUID>,
                                                        to store: CloudStore) async throws -> Int where T.ID == UUID {
        let uploaded = Set(ledger.readAll())
        // Later lines win: an item can be written again with a token or nickname.
        var latest: [UUID: T] = [:]
        for value in file.readAll() where !uploaded.contains(value.id) { latest[value.id] = value }
        let values = Array(latest.values)
        try await store.save(values)
        try ledger.append(contentsOf: values.map(\.id))
        return values.count
    }
}
