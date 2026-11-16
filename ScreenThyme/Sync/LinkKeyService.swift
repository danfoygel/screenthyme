import CloudKit
import Foundation
import ThymeCore

/// Gets the family's nearby-link secret (PLAN.md §16): fetched by name, so phones whose mirror predates it still find
/// it; created by the zone's owner when there is none yet.
enum LinkKeyService {
    static func fetchOrCreate(store: CloudStore) async throws -> LinkKey? {
        let id = CKRecord.ID(recordName: "\(LinkKey.recordType).\(LinkKey.fixedID.uuidString)", zoneID: store.zoneID)
        do {
            return LinkKey.decode(try await store.database.record(for: id))
        } catch let error as CKError where error.code == .unknownItem {
            guard store.family.isOwner else { return nil }
        }
        // Create-only, so two launches racing can't leave phones with different secrets: the loser fetches the winner's.
        let key = LinkKey.generate()
        let (results, _) = try await store.database.modifyRecords(saving: [try key.record(in: store.zoneID)], deleting: [],
                                                                  savePolicy: .ifServerRecordUnchanged)
        switch results[id] {
        case .success?:
            return key
        case let .failure(error as CKError)? where error.code == .serverRecordChanged:
            return LinkKey.decode(try await store.database.record(for: id))
        case let .failure(error)?:
            throw error
        case nil:
            return nil
        }
    }
}
