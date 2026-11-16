import Foundation
import ThymeCore

/// Parent-side actions: rules, pings, health (PLAN.md §4.6, §4.7).
extension AppModel {
    /// How this parent signs grants and pings: their name from Settings, else which side of the share they're on.
    var senderName: String {
        let name = config.parentName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty { return name }
        return config.family?.isOwner == true ? "Parent A" : "Parent B"
    }

    func ping(_ kid: Kid) async {
        guard let store else { return }
        let ping = Ping(kidID: kid.id, at: Date(), from: senderName)
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
        do {
            try await store?.save([rule])
            try await publishRuleSet(for: rule.kidID)
        } catch {
            show(error)
        }
    }

    /// Sends a kid's Screen Time policy; the kid's phone fetches it by name (`KidSync`).
    func save(_ policy: Policy) async {
        var policy = policy
        policy.updatedAt = Date()
        data.ingest(IngestBatch(policies: [policy]))
        do { try await store?.save([policy]) } catch { show(error) }
    }

    /// Answers a kid's request for more time; the kid's phone fetches the grant by name.
    func answer(_ request: TimeRequest, approved: Bool, minutes: Int?) async {
        let grant = TimeGrant(request: request, approved: approved, minutes: minutes, at: Date(), by: senderName)
        data.ingest(IngestBatch(grants: [grant]))
        do { try await store?.save([grant]) } catch { show(error) }
    }

    /// The kid's whole rule list as one record, which the kid's monitor extension fetches by name (`KidSync`).
    private func publishRuleSet(for kidID: UUID) async throws {
        try await store?.save([RuleSet(kidID: kidID, rules: data.rules(for: kidID))])
    }

    /// Development: launched with `-addTestRules <kid name>`, saves one rule of each kid-side kind for that kid, set
    /// to fire soon; `-removeTestRules <kid name>` deletes them. Once per process; the ids are stable, so adding again
    /// updates the rules instead of adding more.
    func handleTestRuleArguments(now: Date = Date()) async {
        let arguments = ProcessInfo.processInfo.arguments
        func kid(after flag: String) -> Kid? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return data.sortedKids.first { $0.displayName == arguments[index + 1] }
        }
        guard !testRulesHandled else { return }
        if let kid = kid(after: "-addTestRules") {
            testRulesHandled = true
            let total = data.fires(kid: kid.id, day: DayKey(now)).map(\.minute).max() ?? 0
            let hour = Calendar.current.component(.hour, from: now) * 60
            let rules = [
                Rule(id: testRuleID("total", kid: kid), kidID: kid.id,
                     condition: .dailyThreshold(itemID: nil, minutes: (total / 5 + 3) * 5)),
                Rule(id: testRuleID("session", kid: kid), kidID: kid.id, condition: .longSession(minutes: 15)),
                Rule(id: testRuleID("quiet", kid: kid), kidID: kid.id,
                     condition: .quietHours(name: "Test quiet hours", startMinute: hour,
                                            endMinute: min(hour + 120, 24 * 60 - 1), weekdays: [], repeatEvery: 30)),
                Rule(id: testRuleID("new", kid: kid), kidID: kid.id, condition: .newApp),
            ]
            data.ingest(IngestBatch(rules: rules))
            do {
                try await store?.save(rules)
                try await publishRuleSet(for: kid.id)
                message = "Added \(rules.count) test rules for \(kid.displayName)."
            } catch {
                show(error)
            }
        } else if let kid = kid(after: "-removeTestRules") {
            testRulesHandled = true
            let names = ["total", "session", "quiet", "new"].map {
                "\(Rule.recordType).\(testRuleID($0, kid: kid).uuidString)"
            }
            data.ingest(IngestBatch(deletedRecordNames: names))
            do {
                try await store?.delete(recordNames: names)
                try await publishRuleSet(for: kid.id)
                message = "Removed the test rules for \(kid.displayName)."
            } catch {
                show(error)
            }
        }
    }

    private func testRuleID(_ name: String, kid: Kid) -> UUID {
        Replay.stableUUID("test-rule", kid.id.uuidString, name)
    }

    func delete(_ rule: Rule) async {
        let name = "\(Rule.recordType).\(rule.id.uuidString)"
        data.ingest(IngestBatch(deletedRecordNames: [name]))
        do {
            try await store?.delete(recordNames: [name])
            try await publishRuleSet(for: rule.kidID)
        } catch {
            show(error)
        }
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
        case .dataAccessLost: "data-access"
        case .activitiesMissing: "activities"
        case .stale: "stale"
        case .backlog: "backlog"
        }
    }
}

@MainActor private var testRulesHandled = false
