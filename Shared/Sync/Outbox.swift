import Foundation
import ThymeCore

/// Uploads App Group outbox files, which the ledger files track.
enum Outbox {
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
