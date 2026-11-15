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

    /// Development: launched with `-addTestRules <kid name>`, saves one rule of each kid-side kind for that kid, set
    /// to fire soon. Once per process; the ids are stable, so launching again updates the rules instead of adding more.
    func addTestRulesIfRequested(now: Date = Date()) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard !testRulesAdded, let flag = arguments.firstIndex(of: "-addTestRules"), flag + 1 < arguments.count,
              let kid = data.sortedKids.first(where: { $0.displayName == arguments[flag + 1] }) else { return }
        testRulesAdded = true
        let total = data.fires(kid: kid.id, day: DayKey(now)).map(\.minute).max() ?? 0
        let hour = Calendar.current.component(.hour, from: now) * 60
        func id(_ name: String) -> UUID { Replay.stableUUID("test-rule", kid.id.uuidString, name) }
        let rules = [
            Rule(id: id("total"), kidID: kid.id, condition: .dailyThreshold(itemID: nil, minutes: (total / 5 + 3) * 5)),
            Rule(id: id("session"), kidID: kid.id, condition: .longSession(minutes: 15)),
            Rule(id: id("quiet"), kidID: kid.id, condition: .quietHours(name: "Test quiet hours", startMinute: hour,
                                                                       endMinute: min(hour + 120, 24 * 60 - 1),
                                                                       weekdays: [], repeatEvery: 30)),
            Rule(id: id("new"), kidID: kid.id, condition: .newApp),
        ]
        data.ingest(IngestBatch(rules: rules))
        do {
            try await store?.save(rules)
            message = "Added \(rules.count) test rules for \(kid.displayName)."
        } catch {
            show(error)
        }
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
        let input = DayInput(fires: data.fires(kid: kid, day: day), samples: data.samples(kid: kid, day: day),
                             dayStart: day.start())
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

@MainActor private var testRulesAdded = false
