import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings
import SwiftUI  // DeviceActivityData.activitySegments and friends are declared in the SwiftUI overlay
import ThymeCore

/// Capture (PLAN.md §13): fetches Apple's per-hour, per-app totals for today (iOS 26.4 data access) and turns the
/// change since the previous fetch into `UsageSample`s, discovering new apps and websites on the way.
enum Sampler {
    /// Apple's totals at the last fetch: hour start (seconds since 1970) → item key → seconds.
    struct Snapshot: Codable {
        var day: DayKey
        var at: Date
        var hours: [String: [String: Double]]
    }

    struct Result: Sendable {
        var samples: [UsageSample] = []
        var newItems: [TrackedItem] = []
        var itemSeconds: [UUID: Double] = [:]
        var intervalSeconds: [UUID: Double] = [:]
    }

    /// One app or website in a fetch.
    private struct Seen {
        var kind: ItemKind
        var identifier: String
        var name: String?
        var tokenData: Data?
        var seconds: Double
    }

    static var isAuthorized: Bool {
        AuthorizationCenter.shared.authorizationStatus == .approvedWithDataAccess
    }

    /// Fetches, writes samples and new items to the outbox, and returns what changed. Serialized across processes.
    static func sample(kid: Kid, now: Date = Date()) async throws -> Result {
        let fetched = try await fetch(now: now)
        return AppGroup.withLock("sampler") { record(fetched, kid: kid, now: now) }
    }

    /// For the extension, whose callbacks are synchronous: waits up to `timeout`.
    static func sampleBlocking(kid: Kid, timeout: TimeInterval = 3) -> Result? {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                box.result = try await sample(kid: kid)
            } catch {
                try? AppGroup.journal.append(.note("sample failed: \(error)"))
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            try? AppGroup.journal.append(.note("sample timed out after \(Int(timeout)) s"))
            return nil
        }
        return box.result
    }

    private final class ResultBox: @unchecked Sendable {
        var result: Result?
    }

    // MARK: - Fetch

    /// Today's per-hour totals, keyed by hour start and item key ("app:<bundle id>" / "web:<domain>").
    nonisolated private static func fetch(now: Date) async throws -> [String: [String: Seen]] {
        let today = Calendar.current.dateInterval(of: .day, for: now)!
        var hours: [String: [String: Seen]] = [:]
        for try await data in DeviceActivityData.activityData(filteredBy: DeviceActivityFilter(segment: .hourly(during: today))) {
            for await segment in data.activitySegments {
                let hour = String(Int(segment.dateInterval.start.timeIntervalSince1970))
                for await category in segment.categories {
                    for await app in category.applications {
                        guard let bundle = app.application.bundleIdentifier, app.totalActivityDuration > 0 else { continue }
                        let token = app.application.token.flatMap(TokenCoding.encode)
                        hours[hour, default: [:]]["app:" + bundle, default: Seen(kind: .app, identifier: bundle,
                            name: app.application.localizedDisplayName, tokenData: token, seconds: 0)].seconds += app.totalActivityDuration
                    }
                    for await site in category.webDomains {
                        guard let domain = site.webDomain.domain, site.totalActivityDuration > 0 else { continue }
                        let token = site.webDomain.token.flatMap(TokenCoding.encode)
                        hours[hour, default: [:]]["web:" + domain, default: Seen(kind: .domain, identifier: domain,
                            name: nil, tokenData: token, seconds: 0)].seconds += site.totalActivityDuration
                    }
                }
            }
        }
        return hours
    }

    // MARK: - Differences

    private static func record(_ hours: [String: [String: Seen]], kid: Kid, now: Date) -> Result {
        let day = DayKey(now)
        let previous = loadSnapshot().flatMap { $0.day == day ? $0 : nil }
        var known = Dictionary(AppGroup.loadItems().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // On the very first fetch everything is "new"; only later discoveries count as new apps.
        let firstEver = known.isEmpty
        var result = Result()

        for (hour, items) in hours {
            guard let hourStart = Double(hour).map(Date.init(timeIntervalSince1970:)) else { continue }
            let hourEnd = hourStart.addingTimeInterval(3600)
            for (key, seen) in items {
                let id = TrackedItem.id(kid: kid.id, kind: seen.kind, identifier: seen.identifier)
                if known[id] == nil {
                    let item = TrackedItem(kidID: kid.id, kind: seen.kind, identifier: seen.identifier, name: seen.name,
                                           tokenData: seen.tokenData, firstSeen: now)
                    known[id] = item
                    if !firstEver { result.newItems.append(item) }
                } else if known[id]?.tokenData == nil, let token = seen.tokenData {
                    known[id]?.tokenData = token
                }
                result.itemSeconds[id, default: 0] += seen.seconds
                let delta = seen.seconds - (previous?.hours[hour]?[key] ?? 0)
                guard delta >= 1 else { continue }
                // Within the hour, the use happened after the previous fetch (or anywhere in it, on a first fetch).
                let start = max(hourStart, previous?.at ?? hourStart)
                let end = min(hourEnd, now)
                result.samples.append(UsageSample(id: Replay.stableUUID("sample", kid.id.uuidString, key, hour, "\(now.timeIntervalSince1970)"),
                                                  kidID: kid.id, itemID: id, day: day,
                                                  start: start < end ? start : hourStart, end: end, seconds: delta))
                result.intervalSeconds[id, default: 0] += delta
            }
        }

        try? AppGroup.samples.append(contentsOf: result.samples)
        let changedItems = known.values.filter { item in result.newItems.contains { $0.id == item.id } || firstEver }
        try? AppGroup.newItems.append(contentsOf: changedItems)
        AppGroup.saveItems(Array(known.values))
        saveSnapshot(Snapshot(day: day, at: now, hours: hours.mapValues { $0.mapValues(\.seconds) }))
        return result
    }

    private static func loadSnapshot() -> Snapshot? {
        guard let data = try? Data(contentsOf: AppGroup.snapshotURL) else { return nil }
        return try? JSONDecoder.thyme.decode(Snapshot.self, from: data)
    }

    private static func saveSnapshot(_ snapshot: Snapshot) {
        try? JSONEncoder.thyme.encode(snapshot).write(to: AppGroup.snapshotURL, options: .atomic)
    }
}
