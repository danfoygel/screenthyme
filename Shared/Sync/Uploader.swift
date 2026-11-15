import Foundation
import ThymeCore

/// Sends journaled fires and queued alerts to CloudKit, then marks them uploaded. Safe to run from the app and the
/// extension at once: record names are the entry ids, so a double upload overwrites. Energy reports ride along in
/// the same request as the fires, so they cost no extra network round trip.
enum Uploader {
    struct Result: Sendable {
        var fires = 0
        var alerts = 0
        var energyReports = 0
    }

    static func flush(config: SharedConfig, days: Int = 7) async throws -> Result {
        guard let family = config.family, let kid = config.kid else { return Result() }
        let store = CloudStore(family: family)
        let journal = AppGroup.journal
        let pending = journal.pending(days: days)
        let epochPrefix = config.epoch.map { RollingLadder.prefix(for: $0.id) }

        var fires: [UsageFire] = []
        for entry in pending {
            // A tracking start travels as a total fire at minute 0, so parents can recognize catch-up bursts.
            let parsed = entry.isTrackingStart ? EventName.Parsed(itemID: nil, minute: 0) : entry.parsedEvent
            guard let parsed else { continue }
            let epochID = epochPrefix.flatMap { entry.activity.hasPrefix($0) ? config.epoch?.id : nil }
            fires.append(UsageFire(id: entry.id, kidID: kid.id, itemID: parsed.itemID, minute: parsed.minute,
                                   firedAt: entry.at, day: DayKey(entry.at, calendar: journal.calendar),
                                   epochID: epochID))
        }
        let energy = EnergyMeter.pendingReports(kid: kid)
        try await store.save(records: fires.map { try $0.record(in: store.zoneID) }
            + energy.map { try $0.record(in: store.zoneID) })
        EnergyMeter.markUploaded(energy)
        // Other interval markers and notes aren't synced; mark them done along with the fires.
        let byDay = Dictionary(grouping: pending) { DayKey($0.at, calendar: journal.calendar) }
        for (day, entries) in byDay {
            try journal.markUploaded(entries.map(\.id), on: day)
        }

        let uploaded = Set(AppGroup.outboxLedger.readAll())
        let alerts = AppGroup.outbox.readAll().filter { !uploaded.contains($0.id) }
        try await store.save(alerts)
        try AppGroup.outboxLedger.append(contentsOf: alerts.map(\.id))

        return Result(fires: fires.count, alerts: alerts.count, energyReports: energy.count)
    }

    /// Re-sends today's and yesterday's tracking-start markers (idempotent). Markers journaled before they were
    /// synced never reached parents, who then draw catch-up bursts as real use.
    static func resendTrackingStarts(config: SharedConfig, now: Date = Date()) async throws {
        guard let family = config.family, let kid = config.kid else { return }
        let journal = AppGroup.journal
        let today = DayKey(now, calendar: journal.calendar)
        let starts = [today.adding(days: -1, calendar: journal.calendar), today]
            .flatMap { journal.entries(on: $0) }
            .filter(\.isTrackingStart)
            .map { UsageFire(id: $0.id, kidID: kid.id, itemID: nil, minute: 0, firedAt: $0.at,
                             day: DayKey($0.at, calendar: journal.calendar), epochID: nil) }
        try await CloudStore(family: family).save(starts)
    }

    static func backlogCount() -> Int {
        AppGroup.journal.pending().filter { $0.kind == .threshold }.count
    }
}
