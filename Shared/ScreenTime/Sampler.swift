import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings
import SwiftUI  // DeviceActivityData.activitySegments and friends are declared in the SwiftUI overlay
import ThymeCore

/// Capture (PLAN.md §13): fetches Apple's per-hour, per-app totals for today (iOS 26.4 data access) and turns the
/// change since the previous fetch into `UsageSample`s, discovering new apps and websites on the way.
enum Sampler {
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
        var category: String?
        var seconds: Double
    }

    /// One fetch: per-hour use by item key, and the categories those items belong to (name → token).
    private struct Fetched {
        var hours: [String: [String: Seen]] = [:]
        var categories: [String: Data?] = [:]
        /// Per-hour pickups and notifications, by the same hour keys.
        var counts: [String: HourCounts] = [:]
    }

    private struct HourCounts {
        var pickupsWithoutApp = 0
        var firstPickup: Date?
        /// By bundle ID.
        var apps: [String: (pickups: Int, notifications: Int)] = [:]
    }

    /// Fetches, writes samples and new items to the outbox, and returns what changed. Serialized across processes.
    static func sample(kid: Kid, now: Date = Date()) async throws -> Result {
        let fetched = try await fetch(now: now)
        return AppGroup.withLock("sampler") { record(fetched, kid: kid, now: now) }
    }

    /// What a sample from the extension got.
    struct Blocking: Sendable {
        var result: Result?
        /// The fetch was refused: the phone has no data access (Apple's Screen Time can take it back, PLAN.md §16).
        var unauthorized = false
    }

    /// For the extension, whose callbacks are synchronous: waits up to `timeout`.
    static func sampleBlocking(kid: Kid, timeout: TimeInterval = 3) -> Blocking {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                box.outcome.result = try await sample(kid: kid)
            } catch {
                // The refusal prints as "unauthorized"; its type isn't documented.
                box.outcome.unauthorized = String(describing: error).contains("unauthorized")
                try? AppGroup.journal.append(.note("sample failed: \(error)"))
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            try? AppGroup.journal.append(.note("sample timed out after \(Int(timeout)) s"))
            return Blocking()
        }
        return box.outcome
    }

    private final class ResultBox: @unchecked Sendable {
        var outcome = Blocking()
    }

    // MARK: - Fetch

    /// Today's per-hour totals, keyed by hour start and item key ("app:<bundle id>" / "web:<domain>").
    nonisolated private static func fetch(now: Date) async throws -> Fetched {
        let today = Calendar.current.dateInterval(of: .day, for: now)!
        var fetched = Fetched()
        for try await data in DeviceActivityData.activityData(filteredBy: DeviceActivityFilter(segment: .hourly(during: today))) {
            for await segment in data.activitySegments {
                let hour = String(Int(segment.dateInterval.start.timeIntervalSince1970))
                fetched.counts[hour, default: HourCounts()].pickupsWithoutApp += segment.totalPickupsWithoutApplicationActivity
                fetched.counts[hour]?.firstPickup = segment.firstPickup
                for await category in segment.categories {
                    let categoryName = category.category.localizedDisplayName
                    if let categoryName, fetched.categories[categoryName] == nil {
                        fetched.categories[categoryName] = category.category.token.flatMap(TokenCoding.encode)
                    }
                    for await app in category.applications {
                        guard let bundle = app.application.bundleIdentifier else { continue }
                        if app.numberOfPickups > 0 || app.numberOfNotifications > 0 {
                            var counts = fetched.counts[hour]?.apps[bundle] ?? (0, 0)
                            counts.pickups += app.numberOfPickups
                            counts.notifications += app.numberOfNotifications
                            fetched.counts[hour]?.apps[bundle] = counts
                        }
                        guard app.totalActivityDuration > 0 else { continue }
                        let token = app.application.token.flatMap(TokenCoding.encode)
                        fetched.hours[hour, default: [:]]["app:" + bundle, default: Seen(kind: .app, identifier: bundle,
                            name: app.application.localizedDisplayName, tokenData: token, category: categoryName,
                            seconds: 0)].seconds += app.totalActivityDuration
                    }
                    for await site in category.webDomains {
                        guard let domain = site.webDomain.domain, site.totalActivityDuration > 0 else { continue }
                        let token = site.webDomain.token.flatMap(TokenCoding.encode)
                        fetched.hours[hour, default: [:]]["web:" + domain, default: Seen(kind: .domain, identifier: domain,
                            name: nil, tokenData: token, category: categoryName, seconds: 0)].seconds += site.totalActivityDuration
                    }
                }
            }
        }
        return fetched
    }

    // MARK: - Differences

    private static func record(_ fetched: Fetched, kid: Kid, now: Date) -> Result {
        let hours = fetched.hours
        let day = DayKey(now)
        let previous = UsageSnapshot.load().flatMap { $0.day == day ? $0 : nil }
        var known = Dictionary(AppGroup.loadItems().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // On the very first fetch everything is "new"; only later discoveries count as new apps.
        let firstEver = known.isEmpty
        var result = Result()
        // Existing items that gained a token or category, to upload again.
        var changed = Set<UUID>()

        // Categories are items too (limit and Always Allowed targets), without samples of their own.
        for (name, token) in fetched.categories {
            let id = TrackedItem.id(kid: kid.id, kind: .category, identifier: name)
            if known[id] == nil {
                known[id] = TrackedItem(kidID: kid.id, kind: .category, identifier: name, name: name, tokenData: token,
                                        firstSeen: now)
                changed.insert(id)
            } else if known[id]?.tokenData == nil, let token {
                known[id]?.tokenData = token
                changed.insert(id)
            }
        }

        for (hour, items) in hours {
            guard let hourStart = Double(hour).map(Date.init(timeIntervalSince1970:)) else { continue }
            let hourEnd = hourStart.addingTimeInterval(3600)
            for (key, seen) in items {
                let id = TrackedItem.id(kid: kid.id, kind: seen.kind, identifier: seen.identifier)
                if known[id] == nil {
                    let item = TrackedItem(kidID: kid.id, kind: seen.kind, identifier: seen.identifier, name: seen.name,
                                           tokenData: seen.tokenData, category: seen.category, firstSeen: now)
                    known[id] = item
                    if !firstEver { result.newItems.append(item) }
                } else if known[id]?.tokenData == nil, let token = seen.tokenData {
                    known[id]?.tokenData = token
                    changed.insert(id)
                }
                if let category = seen.category, known[id]?.category != category {
                    known[id]?.category = category
                    changed.insert(id)
                }
                result.itemSeconds[id, default: 0] += seen.seconds
                let delta = seen.seconds - (previous?.hours[hour]?[key] ?? 0)
                guard delta >= 1 else { continue }
                // Within the hour, the use happened after the previous fetch (or anywhere in it, on a first fetch).
                let start = max(hourStart, previous?.at ?? hourStart)
                let end = min(hourEnd, now)
                result.samples.append(UsageSample(id: Replay.stableUUID("sample", kid.id.uuidString, key, hour, "\(now.timeIntervalSince1970)"),
                                                  kidID: kid.id, itemID: id, day: day,
                                                  start: start < end ? start : hourStart, end: end, seconds: delta,
                                                  reportedAt: now))
                result.intervalSeconds[id, default: 0] += delta
            }
        }

        recordPickups(fetched.counts, kid: kid, day: day, now: now)

        // Apps whose use is Safari's on their website: the first time, from every sample so far.
        var mirror = AppGroup.load(WebMirror.self, from: AppGroup.webMirrorURL) ?? {
            var mirror = WebMirror()
            mirror.add(AppGroup.samples.readAll(), items: known)
            return mirror
        }()
        mirror.add(result.samples, items: known)
        mirror.prune(today: day)
        AppGroup.save(mirror, to: AppGroup.webMirrorURL)

        try? AppGroup.samples.append(contentsOf: result.samples)
        let changedItems = known.values.filter { item in
            firstEver || changed.contains(item.id) || result.newItems.contains { $0.id == item.id }
        }
        try? AppGroup.newItems.append(contentsOf: changedItems)
        AppGroup.saveItems(Array(known.values))
        UsageSnapshot(day: day, at: now, hours: hours.mapValues { $0.mapValues(\.seconds) }).save()
        return result
    }

    /// Queues today's pickup report for upload when its counts changed.
    private static func recordPickups(_ counts: [String: HourCounts], kid: Kid, day: DayKey, now: Date) {
        let hours = counts.compactMap { hour, counts -> PickupReport.Hour? in
            guard let start = Double(hour).map(Date.init(timeIntervalSince1970:)) else { return nil }
            return PickupReport.Hour(start: start, pickupsWithoutApp: counts.pickupsWithoutApp, firstPickup: counts.firstPickup,
                                     apps: counts.apps.map { bundle, counts in
                PickupReport.AppCounts(itemID: TrackedItem.id(kid: kid.id, kind: .app, identifier: bundle), bundleID: bundle,
                                       pickups: counts.pickups, notifications: counts.notifications)
            })
        }
        let report = PickupReport(kidID: kid.id, day: day, updatedAt: now, hours: hours)
        AppGroup.withLock("pickups") {
            var outbox = AppGroup.load(PickupOutbox.self, from: AppGroup.pickupsURL) ?? PickupOutbox()
            if outbox.record(report) { AppGroup.save(outbox, to: AppGroup.pickupsURL) }
        }
    }
}
