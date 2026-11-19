import CloudKit
import Foundation
import ThymeCore

/// The family's GitHub repository and token for bug reports (PLAN.md §18), fetched by name: a parent saves it, kids'
/// phones read it each time they file.
enum IssueTrackerService {
    static func fetch(store: CloudStore) async throws -> IssueTracker? {
        let id = CKRecord.ID(recordName: "\(IssueTracker.recordType).\(IssueTracker.fixedID.uuidString)",
                             zoneID: store.zoneID)
        do {
            return IssueTracker.decode(try await store.database.record(for: id))
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    static func save(_ tracker: IssueTracker, store: CloudStore) async throws {
        try await store.save([tracker])
    }
}
