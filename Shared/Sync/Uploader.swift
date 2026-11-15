import Foundation
import ThymeCore

/// Sends journaled fires and queued alerts to CloudKit, then marks them uploaded. Safe to run from the app and the
/// extension at once: record names are the entry ids, so a double upload overwrites.
enum Uploader {
    struct Result: Sendable {
        var fires = 0
        var alerts = 0
    }

    static func flush(config: SharedConfig, days: Int = 7) async throws -> Result {
        guard let family = config.family, let kid = config.kid else { return Result() }
        let store = CloudStore(family: family)
        let journal = AppGroup.journal
        let pending = journal.pending(days: days)
        let epochPrefix = config.epoch.map { LadderPlanner.prefix(for: $0.id) }

        var fires: [UsageFire] = []
        for entry in pending where entry.kind == .threshold {
            guard let parsed = entry.parsedEvent else { continue }
            let epochID = epochPrefix.flatMap { entry.activity.hasPrefix($0) ? config.epoch?.id : nil }
            fires.append(UsageFire(id: entry.id, kidID: kid.id, itemID: parsed.itemID, minute: parsed.minute,
                                   firedAt: entry.at, day: DayKey(entry.at, calendar: journal.calendar),
                                   epochID: epochID))
        }
        try await store.save(fires)
        // Interval markers aren't synced; mark them done along with the fires.
        let byDay = Dictionary(grouping: pending) { DayKey($0.at, calendar: journal.calendar) }
        for (day, entries) in byDay {
            try journal.markUploaded(entries.map(\.id), on: day)
        }

        let uploaded = Set(AppGroup.outboxLedger.readAll())
        let alerts = AppGroup.outbox.readAll().filter { !uploaded.contains($0.id) }
        try await store.save(alerts)
        try AppGroup.outboxLedger.append(contentsOf: alerts.map(\.id))

        return Result(fires: fires.count, alerts: alerts.count)
    }

    static func backlogCount() -> Int {
        AppGroup.journal.pending().filter { $0.kind == .threshold }.count
    }
}
