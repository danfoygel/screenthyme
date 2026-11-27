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

    /// While the mirror is re-fetched (`FamilyData.isRebuilding`) it can lack a kid's policy and rules, or the
    /// family's places: a save built from it would replace what the kid's phone has.
    var editsBlocked: Bool { data.isRebuilding }

    func refuseWhileRebuilding() -> Bool {
        guard editsBlocked else { return false }
        message = "Still syncing with iCloud. Try again once it finishes."
        return true
    }

    func save(_ rule: Rule) async {
        guard !refuseWhileRebuilding() else { return }
        data.ingest(IngestBatch(rules: [rule]))
        do {
            if let store { try await PendingSaves.save([rule], to: store) }
            try await publishRuleSet(for: rule.kidID)
        } catch {
            show(error)
        }
    }

    /// Sends a kid's Screen Time policy; the kid's phone fetches it by name (`KidSync`) or gets it nearby. Notes the
    /// change, with who made it, in the kid's change history. With `until`, the change is temporary: the kid's phone
    /// changes it back then by itself (`TemporaryChange`, PLAN.md §15.10).
    func save(_ policy: Policy, until: Date? = nil) async {
        guard !refuseWhileRebuilding() else { return }
        let now = Date()
        var policy = policy.current(at: now)
        policy.updatedAt = now
        let before = data.storedPolicy(for: policy.kidID)?.current(at: now)
        let id = UUID()
        if let until {
            policy.temporary.append(TemporaryChange(id: id, until: until, before: before ?? Policy(kidID: policy.kidID),
                                                    after: policy))
        }
        policy.dropSpentTemporaryChanges()
        let change = PolicyChange(id: id, kidID: policy.kidID, at: now, by: senderName, before: before, after: policy,
                                  until: until)
        let changes = change.edits.isEmpty ? [] : [change]
        data.ingest(IngestBatch(policies: [policy], policyChanges: changes))
        nearby.sendUpdates()
        guard let store else { return }
        do {
            try await PendingSaves.save([policy.record(in: store.zoneID)] + changes.map { try $0.record(in: store.zoneID) },
                                        to: store)
        } catch {
            show(error)
        }
    }

    /// Gives a kid's policy a custom category for each of Apple's categories the kid's phone has seen, moves every
    /// use of an Apple category to its custom category (`Policy.withCustomCategories`, PLAN.md §15.14), and puts the
    /// kid's apps and websites where the family's moves have them (`Policy.withFamilyMoves`). Saves, with a change
    /// history entry, only when that changes something. With `onlyStored`, kids with no policy yet are left as they are.
    func setUpCustomCategories(for kid: Kid, onlyStored: Bool = false) async {
        guard !editsBlocked, !onlyStored || data.storedPolicy(for: kid.id) != nil else { return }
        let policy = data.policy(for: kid.id)
        let items = data.items(for: kid.id)
        let updated = policy.withCustomCategories(items: items).withFamilyMoves(data.categoryMoves, items: items)
        if updated != policy { await save(updated) }
    }

    /// Moves an app or website to custom category `groupID` of `kid`'s (nil: back to Apple's category) for every kid:
    /// the same bundle ID or domain moves in each kid's policy (`FamilyCategoryMoves`), saved for each it changes. Kids
    /// with no policy yet get it at set-up.
    func move(_ itemID: UUID, to groupID: UUID?, kid: Kid) async {
        guard !refuseWhileRebuilding(), let item = data.items(for: kid.id)[itemID] else { return }
        let category = groupID.flatMap { id in data.policy(for: kid.id).groups.first { $0.id == id } }?.category
        var moves = data.categoryMoves
        moves.move(item, to: category)
        for other in data.sortedKids where other.id == kid.id || data.storedPolicy(for: other.id) != nil {
            let policy = data.policy(for: other.id)
            let updated = policy.withFamilyMoves(moves, items: data.items(for: other.id))
            if updated != policy { await save(updated) }
        }
    }

    /// Answers a kid's request for more time; the kid's phone fetches the grant by name or gets it nearby. Offline,
    /// the grant waits in `PendingSaves`. Approving a request to always allow an app saves the policy with it allowed
    /// first.
    func answer(_ request: TimeRequest, approved: Bool, minutes: Int?) async {
        let grant = TimeGrant(request: request, approved: approved, minutes: minutes, at: Date(), by: senderName)
        let policy = data.policy(for: request.kidID)
        let allowing = policy.applying(grant)
        if allowing != policy {
            guard !refuseWhileRebuilding() else { return }
            await save(allowing)
        }
        data.ingest(IngestBatch(grants: [grant]))
        nearby.sendUpdates()
        guard let store else { return }
        do { try await PendingSaves.save([grant], to: store) } catch { show(error) }
    }

    /// Ends a running approval early, a parent's or the kid's own (PLAN.md §15.12): the same record, with its end. The
    /// kid's phone fetches it at its next wake or gets it nearby, and blocks again.
    func end(_ grant: TimeGrant) async {
        guard grant.endedAt == nil else { return }
        let ended = grant.ending(at: Date(), by: senderName)
        data.ingest(IngestBatch(grants: [ended]))
        nearby.sendUpdates()
        guard let store else { return }
        do { try await PendingSaves.save([ended], to: store) } catch { show(error) }
    }

    /// The kid's whole rule list as one record, which the kid's monitor extension fetches by name (`KidSync`), and
    /// this phone sends to the kid's phone nearby.
    private func publishRuleSet(for kidID: UUID) async throws {
        let set = RuleSet(kidID: kidID, rules: data.rules(for: kidID))
        rememberPublished(set)
        nearby.sendUpdates()
        if let store { try await PendingSaves.save([set], to: store) }
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
        guard !refuseWhileRebuilding() else { return }
        let name = "\(Rule.recordType).\(rule.id.uuidString)"
        data.ingest(IngestBatch(deletedRecordNames: [name]))
        // The rule set is what kid phones read, so it goes out even when the deletion can't (offline).
        do { try await store?.delete(recordNames: [name]) } catch { show(error) }
        do { try await publishRuleSet(for: rule.kidID) } catch { show(error) }
    }

    /// Apps used on the kid's phone lately that no scanned app is matched to (`TokenPairing.unmatched`), newest first: those
    /// a match round may match, and those the app scan doesn't list. None before the phone's first match (its
    /// latest heartbeat says when), which the kid's phone starts.
    func unmatchedApps(for kid: Kid) -> TokenPairing.Unmatched {
        guard let last = data.heartbeats[kid.id]?.lastTokenPairing else { return TokenPairing.Unmatched() }
        let today = DayKey(Date())
        let items = data.items(for: kid.id)
        // Not those whose use is Safari's on their website: they aren't installed, so no scan lists them.
        let used = Set((0..<TokenPairing.days).flatMap { data.samples(kid: kid.id, day: today.adding(days: -$0)) }.map(\.itemID))
            .subtracting(data.webMirrored(kid: kid.id, items: items, today: today))
        var unmatched = TokenPairing.unmatched(Array(items.values), lastImport: last, used: used)
        unmatched.toMatch.sort { $0.firstSeen > $1.firstSeen }
        unmatched.toScan.sort { $0.firstSeen > $1.firstSeen }
        return unmatched
    }

    /// The kid phone's charge from its heartbeat or its energy reports, whichever came last.
    func battery(for kid: Kid) -> BatteryReading? {
        BatteryReading.latest(heartbeat: data.heartbeats[kid.id], reports: data.energyReports(for: kid.id))
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
        var input = DayInput(fires: data.fires(kid: kid, day: day), samples: data.samples(kid: kid, day: day),
                             dayStart: day.start())
        let items = data.items(for: kid).values
        input.websites = Set(items.filter { $0.kind == .domain }.map(\.id))
        input.browsers = Set(items.filter { $0.kind == .app && BuiltInApps.showsWebsites($0.identifier) }.map(\.id))
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
        case let .permissionDenied(permission): "permission.\(permission.rawValue)"
        case .lowPowerMode: "low-power"
        }
    }
}

@MainActor private var testRulesHandled = false

extension FamilyData {
    /// A kid's policy on `day`: as it is now for today, as it was at the day's end before.
    func policy(on day: DayKey, kid: UUID) -> Policy {
        guard day < DayKey(Date()) else { return policy(for: kid) }
        return storedPolicy(for: kid, at: day.end().addingTimeInterval(-1)) ?? policy(for: kid)
    }

    /// A kid's apps whose use in the week to `today` was Safari's on their website (`WebMirror`), from the kid's samples.
    func webMirrored(kid: UUID, items: [UUID: TrackedItem], today: DayKey) -> Set<UUID> {
        var mirror = WebMirror()
        for days in 0..<WebMirror.days { mirror.add(samples(kid: kid, day: today.adding(days: -days)), items: items) }
        return mirror.mirrored(items: items, today: today)
    }
}
