import CloudKit
import Foundation
import ThymeCore

/// Every synced type is stored as a JSON `payload` plus a few plain fields for queries and push text.
/// Record name = "<type>.<uuid>", so re-uploading the same value overwrites instead of duplicating.
protocol CloudRecordable: Codable, Sendable {
    static var recordType: String { get }
    var recordUUID: UUID { get }
    var ownerKidID: UUID { get }
    func addFields(to record: CKRecord)
}

extension CloudRecordable {
    func addFields(to record: CKRecord) {}

    func record(in zoneID: CKRecordZone.ID) throws -> CKRecord {
        let id = CKRecord.ID(recordName: "\(Self.recordType).\(recordUUID.uuidString)", zoneID: zoneID)
        let record = CKRecord(recordType: Self.recordType, recordID: id)
        record["kidID"] = ownerKidID.uuidString
        record["payload"] = try JSONEncoder.thyme.encode(self)
        addFields(to: record)
        return record
    }

    static func decode(_ record: CKRecord) -> Self? {
        guard record.recordType == recordType, let data = record["payload"] as? Data else { return nil }
        return decode(payload: data)
    }

    static func decode(payload: Data) -> Self? {
        try? JSONDecoder.thyme.decode(Self.self, from: payload)
    }
}

extension Kid: CloudRecordable {
    static let recordType = "Kid"
    var recordUUID: UUID { id }
    var ownerKidID: UUID { id }
}

extension TrackedItem: CloudRecordable {
    static let recordType = "TrackedItem"
    var recordUUID: UUID { id }
    var ownerKidID: UUID { kidID }
}

extension LadderEpoch: CloudRecordable {
    static let recordType = "LadderEpoch"
    var recordUUID: UUID { id }
    var ownerKidID: UUID { kidID }
}

extension UsageFire: CloudRecordable {
    static let recordType = "UsageFire"
    var recordUUID: UUID { id }
    var ownerKidID: UUID { kidID }

    func addFields(to record: CKRecord) {
        record["day"] = day.description
        record["firedAt"] = firedAt
    }
}

extension UsageSample: CloudRecordable {
    static let recordType = "UsageSample"
    var recordUUID: UUID { id }
    var ownerKidID: UUID { kidID }

    func addFields(to record: CKRecord) {
        record["day"] = day.description
        record["end"] = end
    }
}

extension Heartbeat: CloudRecordable {
    static let recordType = "Heartbeat"
    var recordUUID: UUID { id }
    var ownerKidID: UUID { kidID }
}

extension EnergyReport: CloudRecordable {
    static let recordType = "EnergyReport"
    var recordUUID: UUID { id }
    var ownerKidID: UUID { kidID }

    func addFields(to record: CKRecord) {
        record["day"] = day.description
    }
}

extension AlertRecord: CloudRecordable {
    static let recordType = "Alert"
    var recordUUID: UUID { id }
    var ownerKidID: UUID { kidID }

    /// Read by the owner's CKQuerySubscription to build a visible push without waking the app.
    func addFields(to record: CKRecord) {
        record["title"] = title
        record["body"] = body
        record["at"] = at
    }
}

extension Rule: CloudRecordable {
    static let recordType = "Rule"
    var recordUUID: UUID { id }
    var ownerKidID: UUID { kidID }
}

extension RuleSet: CloudRecordable {
    static let recordType = "RuleSet"
    var recordUUID: UUID { kidID }
    var ownerKidID: UUID { kidID }
}

/// One per kid, fetched by name on the kid's phone (`KidSync`).
extension Policy: CloudRecordable {
    static let recordType = "Policy"
    var recordUUID: UUID { kidID }
    var ownerKidID: UUID { kidID }
}

/// The change history (`PolicyChange`); only parents' phones read it.
extension PolicyChange: CloudRecordable {
    static let recordType = "PolicyChange"
    var recordUUID: UUID { id }
    var ownerKidID: UUID { kidID }
}

extension TimeRequest: CloudRecordable {
    static let recordType = "TimeRequest"
    var recordUUID: UUID { id }
    var ownerKidID: UUID { kidID }
}

/// Named after its request, so the kid's phone can fetch the answer by name.
extension TimeGrant: CloudRecordable {
    static let recordType = "TimeGrant"
    var recordUUID: UUID { requestID }
    var ownerKidID: UUID { kidID }
}

extension ExtraMinuteUse: CloudRecordable {
    static let recordType = "ExtraMinuteUse"
    var recordUUID: UUID { id }
    var ownerKidID: UUID { kidID }
}

extension Ping: CloudRecordable {
    static let recordType = "Ping"
    var recordUUID: UUID { id }
    var ownerKidID: UUID { kidID }
}

/// One per family, under a fixed name; belongs to no kid.
extension LinkKey: CloudRecordable {
    static let recordType = "LinkKey"
    var recordUUID: UUID { id }
    var ownerKidID: UUID { id }
}

/// Where kids' phones file bug reports (PLAN.md §18): one per family, under a fixed name; belongs to no kid.
extension IssueTracker: CloudRecordable {
    static let recordType = "IssueTracker"
    var recordUUID: UUID { id }
    var ownerKidID: UUID { id }
}

/// Where a kid's phone was (PLAN.md §19): only parents' phones keep them.
extension PlaceEvent: CloudRecordable {
    static let recordType = "PlaceEvent"
    var recordUUID: UUID { id }
    /// `kidID` is set before upload (`Uploader`).
    var ownerKidID: UUID { kidID ?? id }

    func addFields(to record: CKRecord) {
        record["day"] = day.description
    }
}

/// One per family, under a fixed name; belongs to no kid. Kids' phones fetch it by name (`KidSync`).
extension FamilyPlaces: CloudRecordable {
    static let recordType = "FamilyPlaces"
    var recordUUID: UUID { id }
    var ownerKidID: UUID { id }
}

/// Saves to the family zone. Used by the app and (for uploads) the monitor extension.
struct CloudStore: Sendable {
    static let zoneName = "Family"

    let family: FamilyLocation

    var container: CKContainer { CKContainer(identifier: AppGroup.cloudContainer) }

    var database: CKDatabase {
        family.isOwner ? container.privateCloudDatabase : container.sharedCloudDatabase
    }

    var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: family.zoneName, ownerName: family.ownerName)
    }

    func save<T: CloudRecordable>(_ values: [T]) async throws {
        try await save(records: values.map { try $0.record(in: zoneID) })
    }

    /// Records of any types, in as few requests as possible.
    func save(records: [CKRecord]) async throws {
        guard !records.isEmpty else { return }
        // CloudKit accepts up to 400 records per request.
        for start in stride(from: 0, to: records.count, by: 350) {
            let chunk = Array(records[start..<min(start + 350, records.count)])
            let (results, _) = try await database.modifyRecords(saving: chunk, deleting: [], savePolicy: .allKeys,
                                                                atomically: false)
            for (_, result) in results {
                if case let .failure(error) = result { throw error }
            }
        }
    }

    func delete(recordNames: [String]) async throws {
        let ids = recordNames.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        _ = try await database.modifyRecords(saving: [], deleting: ids)
    }
}
