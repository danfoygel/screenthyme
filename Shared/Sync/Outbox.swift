import Foundation
import ThymeCore

/// Uploads App Group outbox files, which the ledger files track.
enum Outbox {
    /// Uploads the latest version of each record the ledger doesn't list yet, then records it there.
    /// - Parameter versioned: the outbox rewrites records (items), so the ledger lists versions, not ids.
    static func send<T: CloudRecordable & Identifiable>(_ file: JSONLinesFile<T>, ledger: JSONLinesFile<UUID>,
                                                        versioned: Bool = false,
                                                        to store: CloudStore) async throws -> Int where T.ID == UUID {
        func key(_ value: T) -> UUID { versioned ? OutboxPending.version(of: value) : value.id }
        let values = OutboxPending.pending(file.readAll(), uploaded: Set(ledger.readAll()), key: key)
        try await store.save(values)
        try ledger.append(contentsOf: values.map(key))
        return values.count
    }
}
