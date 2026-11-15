import CloudKit
import Foundation
import ThymeCore

/// Family zone, sharing and subscriptions (PLAN.md §4.3).
enum FamilyService {
    static var container: CKContainer { CKContainer(identifier: AppGroup.cloudContainer) }

    /// Parent A: creates the zone in their private database.
    static func createFamily() async throws -> FamilyLocation {
        let zone = CKRecordZone(zoneName: CloudStore.zoneName)
        _ = try await container.privateCloudDatabase.modifyRecordZones(saving: [zone], deleting: [])
        return FamilyLocation(zoneName: CloudStore.zoneName, ownerName: CKCurrentUserDefaultName, isOwner: true)
    }

    /// The zone-wide share Parent A sends to Parent B and each kid's Apple ID.
    static func share(for family: FamilyLocation) async throws -> CKShare {
        let store = CloudStore(family: family)
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: store.zoneID)
        if let existing = try? await store.database.record(for: shareID) as? CKShare {
            return existing
        }
        let share = CKShare(recordZoneID: store.zoneID)
        share[CKShare.SystemFieldKey.title] = "ScreenThyme family"
        share.publicPermission = .none
        let (results, _) = try await store.database.modifyRecords(saving: [share], deleting: [])
        guard let saved = try results[share.recordID]?.get() as? CKShare else { throw CKError(.internalError) }
        return saved
    }

    static func accept(_ metadata: CKShare.Metadata) async throws -> FamilyLocation {
        _ = try await container.accept(metadata)
        let zoneID = metadata.share.recordID.zoneID
        return FamilyLocation(zoneName: zoneID.zoneName, ownerName: zoneID.ownerName, isOwner: false)
    }

    /// Silent pushes for every zone change; on the owner's parent device also a visible push per Alert, built by
    /// CloudKit from the record's title/body without waking the app.
    static func installSubscriptions(family: FamilyLocation, isParent: Bool) async throws {
        let store = CloudStore(family: family)
        let silent = CKSubscription.NotificationInfo()
        silent.shouldSendContentAvailable = true

        if family.isOwner {
            let zone = CKRecordZoneSubscription(zoneID: store.zoneID, subscriptionID: "family-zone")
            zone.notificationInfo = silent
            var subscriptions: [CKSubscription] = [zone]
            if isParent {
                let alerts = CKQuerySubscription(recordType: AlertRecord.recordType, predicate: NSPredicate(value: true),
                                                 subscriptionID: "alerts-visible", options: [.firesOnRecordCreation])
                alerts.zoneID = store.zoneID
                let info = CKSubscription.NotificationInfo()
                info.titleLocalizationKey = "%1$@"
                info.titleLocalizationArgs = ["title"]
                info.alertLocalizationKey = "%1$@"
                info.alertLocalizationArgs = ["body"]
                info.soundName = "default"
                alerts.notificationInfo = info
                subscriptions.append(alerts)
            }
            _ = try await store.database.modifySubscriptions(saving: subscriptions, deleting: [])
        } else {
            let shared = CKDatabaseSubscription(subscriptionID: "shared-db")
            shared.notificationInfo = silent
            _ = try await store.database.modifySubscriptions(saving: [shared], deleting: [])
        }
    }
}

/// Incremental fetch of the family zone, with the change token kept per zone.
enum ChangeFetcher {
    static func fetch(store: CloudStore) async throws -> IngestBatch {
        let key = "changeToken.\(store.zoneID.ownerName).\(store.zoneID.zoneName)"
        var token = loadToken(key)
        var batch = IngestBatch()
        var moreComing = true
        while moreComing {
            let changes: (modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, any Error>],
                          deletions: [CKDatabase.RecordZoneChange.Deletion],
                          changeToken: CKServerChangeToken,
                          moreComing: Bool)
            do {
                changes = try await store.database.recordZoneChanges(inZoneWith: store.zoneID, since: token)
            } catch let error as CKError where error.code == .changeTokenExpired {
                token = nil
                continue
            }
            for (_, result) in changes.modificationResultsByID {
                if case let .success(modification) = result {
                    batch.add(modification.record)
                }
            }
            batch.deletedRecordNames += changes.deletions.map(\.recordID.recordName)
            token = changes.changeToken
            moreComing = changes.moreComing
        }
        saveToken(token, key: key)
        return batch
    }

    static func resetToken(for store: CloudStore) {
        UserDefaults.standard.removeObject(forKey: "changeToken.\(store.zoneID.ownerName).\(store.zoneID.zoneName)")
    }

    private static func loadToken(_ key: String) -> CKServerChangeToken? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    private static func saveToken(_ token: CKServerChangeToken?, key: String) {
        guard let token, let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
