import Foundation
import ThymeCore

/// Parent-side actions: rules, pings, health (PLAN.md §4.6, §4.7).
extension AppModel {
    func ping(_ kid: Kid) async {
        guard let store else { return }
        let ping = Ping(kidID: kid.id, at: Date(), from: config.family?.isOwner == true ? "Parent A" : "Parent B")
        do {
            try await store.save([ping])
            data.ingest(IngestBatch(pings: [ping]))
            message = "Pinged \(kid.displayName)'s phone."
        } catch {
            show(error)
        }
    }

    func save(_ rule: Rule) async {
        data.ingest(IngestBatch(rules: [rule]))
        do { try await store?.save([rule]) } catch { show(error) }
    }

    func delete(_ rule: Rule) async {
        let name = "\(Rule.recordType).\(rule.id.uuidString)"
        data.ingest(IngestBatch(deletedRecordNames: [name]))
        do { try await store?.delete(recordNames: [name]) } catch { show(error) }
    }

    func healthIssues(for kid: Kid, now: Date = Date()) -> [HealthIssue] {
        let staleness = data.rules(for: kid.id).lazy.compactMap { rule -> (Int, Int, Int)? in
            guard rule.enabled, case let .staleness(hours, start, end) = rule.condition else { return nil }
            return (hours, start, end)
        }.first ?? (3, 7 * 60, 22 * 60)
        return HealthEvaluator.issues(latest: data.heartbeats[kid.id], lastFireAt: data.lastFireAt[kid.id], now: now,
                                      staleHours: staleness.0, wakingStartMinute: staleness.1,
                                      wakingEndMinute: staleness.2)
    }

    /// Notifies each urgent issue once until it clears.
    func notifyHealthIssues() {
        let defaults = UserDefaults.standard
        var notified = Set(defaults.stringArray(forKey: "notifiedHealthIssues") ?? [])
        var current = Set<String>()
        for kid in data.sortedKids where !kid.isTest {
            for issue in healthIssues(for: kid) where issue.isUrgent {
                let key = "\(kid.id).\(issue.kind)"
                current.insert(key)
                if !notified.contains(key) {
                    Notifier.post(id: key, title: "\(kid.displayName)'s phone", body: issue.summary)
                }
            }
        }
        notified = current
        defaults.set(Array(notified), forKey: "notifiedHealthIssues")
    }

    func timeline(kid: UUID, day: DayKey) -> (input: DayInput, timeline: DayTimeline) {
        let spec = data.epochs.values.filter { $0.kidID == kid }.max { $0.startedAt < $1.startedAt }?.spec ?? .standard
        let items = data.items(for: kid).values
        let websites = Set(items.filter { $0.kind == .domain }.map(\.id))
        let categories = Set(items.filter { $0.kind == .category }.map(\.id))
        let input = DayInput(fires: data.fires(kid: kid, day: day), dayStart: day.start(), spec: spec,
                             shortItems: websites, totalsOnlyItems: websites.union(categories))
        return (input, Reconstructor.build(input))
    }
}

extension HealthIssue {
    /// Stable per kind, so "offline since 3:12" and "offline since 3:40" count as the same issue.
    var kind: String {
        switch self {
        case .neverReported: "never"
        case .notAuthorized: "auth"
        case .activitiesMissing: "activities"
        case .stale: "stale"
        case .backlog: "backlog"
        }
    }
}
