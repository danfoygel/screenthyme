import Foundation
import ThymeCore

/// Sends journaled fires, samples, new items and queued alerts to CloudKit, then marks them uploaded. Energy reports
/// ride along in the same request as the fires, so they cost no extra network round trip. Safe to run from the app
/// and the extension at once: record names are the entry ids, so a double upload overwrites.
enum Uploader {
    struct Result: Sendable {
        var fires = 0
        var samples = 0
        var alerts = 0
        var energyReports = 0
    }

    static func flush(config: SharedConfig, days: Int = 7) async throws -> Result {
        guard let family = config.family, let kid = config.kid else { return Result() }
        let store = CloudStore(family: family)
        let journal = AppGroup.journal
        let pending = journal.pending(days: days)
        let fires = fires(from: pending, kid: kid, epochID: config.epoch?.id, calendar: journal.calendar)
        let energy = EnergyMeter.pendingReports(kid: kid)
        try await store.save(records: fires.map { try $0.record(in: store.zoneID) }
            + energy.map { try $0.record(in: store.zoneID) })
        EnergyMeter.markUploaded(energy)
        for (day, entries) in Dictionary(grouping: pending, by: { DayKey($0.at, calendar: journal.calendar) }) {
            try journal.markUploaded(entries.map(\.id), on: day)
        }

        _ = try await Outbox.send(AppGroup.newItems, ledger: AppGroup.newItemsLedger, versioned: true, to: store)
        let samples = try await Outbox.send(AppGroup.samples, ledger: AppGroup.samplesLedger, to: store)
        _ = try await Outbox.send(AppGroup.requests, ledger: AppGroup.requestsLedger, to: store)
        _ = try await Outbox.send(AppGroup.extraMinuteUses, ledger: AppGroup.extraMinuteUsesLedger, to: store)
        let alerts = try await Outbox.send(AppGroup.outbox, ledger: AppGroup.outboxLedger, to: store)
        return Result(fires: fires.count, samples: samples, alerts: alerts, energyReports: energy.count)
    }

    /// Total fires, and tracking starts as minute-0 fires. Item fires from the old per-app ladders are dropped.
    static func fires(from entries: [JournalEntry], kid: Kid, epochID: UUID?, calendar: Calendar) -> [UsageFire] {
        entries.compactMap { entry in
            let parsed = entry.isTrackingStart ? EventName.Parsed(itemID: nil, minute: 0) : entry.parsedEvent
            guard let parsed, parsed.itemID == nil else { return nil }
            return UsageFire(id: entry.id, kidID: kid.id, itemID: nil, minute: parsed.minute, firedAt: entry.at,
                             day: DayKey(entry.at, calendar: calendar), epochID: epochID)
        }
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
        let uploaded = Set(AppGroup.samplesLedger.readAll())
        return AppGroup.journal.pending().filter { $0.kind == .threshold }.count
            + AppGroup.samples.readAll().filter { !uploaded.contains($0.id) }.count
    }
}
