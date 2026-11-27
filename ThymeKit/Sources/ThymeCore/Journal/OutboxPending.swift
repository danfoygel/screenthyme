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

    /// The latest version of each record in `lines` whose ledger entry (`key`: its id, or its `version`) isn't the last
    /// one `uploaded` lists for that record. A version can come back (a scan took an item's token and a pick gave it
    /// back, with the same match), and its old entry doesn't count once another version went up after it.
    /// - Parameter uploaded: the ledger, in the order it was written.
    public static func pending<T: Identifiable>(_ lines: [T], uploaded: [UUID], key: (T) -> UUID) -> [T]
        where T.ID == UUID {
        var latest: [UUID: T] = [:]
        var order: [UUID] = []
        var record: [UUID: UUID] = [:]  // each version's record
        for value in lines {
            if latest.updateValue(value, forKey: value.id) == nil { order.append(value.id) }
            record[key(value)] = value.id
        }
        var lastUploaded: [UUID: UUID] = [:]
        for entry in uploaded {
            if let id = record[entry] { lastUploaded[id] = entry }
        }
        return order.compactMap { latest[$0] }.filter { lastUploaded[$0.id] != key($0) }
    }
}
