import Foundation

/// What an outbox still has to upload: the latest version of each record (later lines win), unless the upload ledger
/// lists it. Most outboxes hold one version per record, and their ledgers list ids. The items outbox holds several
/// (an item written again with a token, a nickname or a token match), so its ledger lists versions: a newer version
/// of an item already uploaded still goes up.
public enum OutboxPending {
    /// The ledger entry for this version of a record: its id and its content.
    public static func version<T: Identifiable & Encodable>(of value: T) -> UUID where T.ID == UUID {
        let content = (try? JSONEncoder.thyme.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return Replay.stableUUID("outbox", value.id.uuidString, content)
    }

    /// The latest version of each record in `lines` whose ledger entry (`key`: its id, or its `version`) `uploaded`
    /// doesn't list.
    public static func pending<T: Identifiable>(_ lines: [T], uploaded: Set<UUID>, key: (T) -> UUID) -> [T]
        where T.ID == UUID {
        var latest: [UUID: T] = [:]
        var order: [UUID] = []
        for value in lines {
            if latest.updateValue(value, forKey: value.id) == nil { order.append(value.id) }
        }
        return order.compactMap { latest[$0] }.filter { !uploaded.contains(key($0)) }
    }
}
