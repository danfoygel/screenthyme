import CloudKit
import CoreLocation
import SwiftUI
import ThymeCore

/// How many records the family zone holds, and how big they are, by kid, record type and age. Reads the whole zone
/// from iCloud on each scan (without touching the change token or the local mirror).
struct CloudRecordsView: View {
    @Environment(AppModel.self) private var model
    @State private var records: [RecordSummary]?
    @State private var scanned = 0
    @State private var scanning = false
    @State private var error: String?
    /// Narrows the type and age sections.
    @State private var kidFilter: KidFilter = .all

    enum KidFilter: Hashable {
        case all
        /// nil: the family's own records.
        case kid(UUID?)
    }

    var body: some View {
        Form {
            Section {
                Button(scanning ? "Scanning… \(scanned) records" : records == nil ? "Scan iCloud" : "Scan again") {
                    Task { await scan() }
                }
                .disabled(scanning || model.config.family == nil)
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            } footer: {
                Text("Downloads every record of the family zone. Sizes are the records' field data; CloudKit's own metadata isn't counted.")
            }
            if let records {
                let stats = RecordStats(records)
                Section("All") {
                    row("Records", stats.total)
                }
                Section("By kid") {
                    ForEach(kidKeys(stats), id: \.self) { kid in
                        row(kidName(kid), stats.byKid[kid] ?? RecordTally())
                    }
                }
                Section {
                    Picker("Kid", selection: $kidFilter) {
                        Text("Everyone").tag(KidFilter.all)
                        ForEach(kidKeys(stats), id: \.self) { kid in
                            Text(kidName(kid)).tag(KidFilter.kid(kid))
                        }
                    }
                }
                let filtered = filtered(records)
                Section("By record type") {
                    ForEach(filtered.typesBySize, id: \.type) { type, tally in
                        row(type, tally)
                    }
                }
                Section("By age (created)") {
                    ForEach(filtered.ages, id: \.age) { age, tally in
                        row(age.title, tally)
                    }
                }
            }
        }
        .navigationTitle("CloudKit records")
        .bugButton()
    }

    private func row(_ title: String, _ tally: RecordTally) -> some View {
        LabeledContent(title) {
            Text("\(tally.count) · \(tally.bytes.formatted(.byteCount(style: .file)))").monospacedDigit()
        }
    }

    private func filtered(_ records: [RecordSummary]) -> RecordStats {
        switch kidFilter {
        case .all: RecordStats(records)
        case let .kid(kid): RecordStats(records.filter { $0.kidID == kid })
        }
    }

    /// Kids by name, then kids no longer in the family, then the family's own records.
    private func kidKeys(_ stats: RecordStats) -> [UUID?] {
        stats.byKid.keys.sorted { a, b in
            (rank(a), kidName(a)) < (rank(b), kidName(b))
        }
    }

    private func rank(_ kid: UUID?) -> Int {
        guard let kid else { return 2 }
        return model.data.kids[kid] == nil ? 1 : 0
    }

    private func kidName(_ kid: UUID?) -> String {
        guard let kid else { return "Family" }
        return model.data.kids[kid]?.displayName ?? "Removed kid \(kid.uuidString.prefix(8))"
    }

    private func scan() async {
        guard let family = model.config.family else { return }
        scanning = true
        scanned = 0
        error = nil
        defer { scanning = false }
        do {
            records = try await CloudRecordScan.run(store: CloudStore(family: family)) { scanned = $0 }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Every record of the family zone, fetched from scratch and reduced to what `RecordStats` counts.
enum CloudRecordScan {
    /// Records that belong to the family rather than a kid: their `kidID` field is their own id, or missing.
    private static let familyTypes: Set<String> = [LinkKey.recordType, IssueTracker.recordType, FamilyPlaces.recordType,
                                                   CKRecord.SystemType.share]

    static func run(store: CloudStore, progress: @MainActor (Int) -> Void) async throws -> [RecordSummary] {
        var token: CKServerChangeToken?
        var summaries: [RecordSummary] = []
        var moreComing = true
        while moreComing {
            let changes = try await store.database.recordZoneChanges(inZoneWith: store.zoneID, since: token)
            for (_, result) in changes.modificationResultsByID {
                if case let .success(modification) = result {
                    summaries.append(summary(of: modification.record))
                }
            }
            token = changes.changeToken
            moreComing = changes.moreComing
            await progress(summaries.count)
        }
        return summaries
    }

    static func summary(of record: CKRecord) -> RecordSummary {
        let kidID = familyTypes.contains(record.recordType) ? nil : (record["kidID"] as? String).flatMap(UUID.init)
        let bytes = record.allKeys().reduce(0) { $0 + size(of: record[$1]) }
        return RecordSummary(type: record.recordType, kidID: kidID, bytes: bytes,
                             createdAt: record.creationDate ?? record.modificationDate)
    }

    private static func size(of value: (any CKRecordValueProtocol)?) -> Int {
        switch value {
        case nil: 0
        case let data as Data: data.count
        case let string as String: string.utf8.count
        case is Date, is NSNumber, is Int, is Double, is Bool: 8
        case let asset as CKAsset:
            asset.fileURL.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 0
        case let reference as CKRecord.Reference: reference.recordID.recordName.utf8.count
        case is CLLocation: 32
        case let array as [any CKRecordValueProtocol]: array.reduce(0) { $0 + size(of: $1) }
        default: 0
        }
    }
}
