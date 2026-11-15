import CloudKit
import Foundation
import ThymeCore

/// Keeps a kid phone's rules, policy and answers to its requests current without relying on silent pushes, which
/// iOS rations (PLAN.md §14, §15). The monitor extension fetches `RuleSet.<kid>` and `Policy.<kid>` by name at most
/// every `interval`, and `TimeGrant.<request>` for open requests at every wake.
enum KidSync {
    static let interval: TimeInterval = 10 * 60

    static func refreshIfDue(config: SharedConfig, now: Date = Date(), force: Bool = false) async {
        guard let family = config.family, let kid = config.kid else { return }
        let local = AppGroup.loadRules()
        let due = force || now.timeIntervalSince(local?.checkedAt ?? .distantPast) >= interval
        let open = openRequests(now: now)
        guard due || !open.isEmpty else { return }

        let store = CloudStore(family: family)
        func id(_ type: String, _ uuid: UUID) -> CKRecord.ID {
            CKRecord.ID(recordName: "\(type).\(uuid.uuidString)", zoneID: store.zoneID)
        }
        let ruleSetID = id(RuleSet.recordType, kid.id)
        let policyID = id(Policy.recordType, kid.id)
        var ids = open.map { id(TimeGrant.recordType, $0.id) }
        if due { ids += [ruleSetID, policyID] }
        do {
            let results = try await store.database.records(for: ids)
            for (recordID, result) in results {
                switch result {
                case let .success(record):
                    if let set = RuleSet.decode(record) {
                        saveRules(set.rules, checkedAt: now)
                    } else if let policy = Policy.decode(record) {
                        savePolicy(policy)
                    } else if let grant = TimeGrant.decode(record) {
                        Enforcer.apply(grant, now: now)
                    }
                case let .failure(error as CKError) where error.code == .unknownItem:
                    // No RuleSet yet: keep what we have. No Policy: nothing to enforce. No grant: still waiting.
                    if recordID == ruleSetID { saveRules(local?.rules ?? config.rules, checkedAt: now) }
                case let .failure(error):
                    try? AppGroup.journal.append(.note("kid sync: \(recordID.recordName): \(error)"))
                }
            }
        } catch {
            try? AppGroup.journal.append(.note("kid sync failed: \(error)"))
        }
    }

    /// Today's requests without an answer yet.
    static func openRequests(now: Date = Date()) -> [TimeRequest] {
        let answered = Set(Enforcer.loadState(now: now).grants.map(\.grant.requestID))
        let today = DayKey(now)
        return AppGroup.requests.readAll().filter { DayKey($0.at) == today && !answered.contains($0.id) }
    }

    /// Writes the rules if they changed; always records the check.
    static func saveRules(_ rules: [Rule], checkedAt: Date) {
        AppGroup.withLock("rules") {
            let current = AppGroup.loadRules()
            if let current, Set(current.rules) != Set(rules) {
                try? AppGroup.journal.append(.note("rules updated: \(rules.count)"))
            }
            AppGroup.saveRules(LocalRules(rules: rules, checkedAt: checkedAt))
        }
    }

    /// Stores a newer policy and enforces it.
    static func savePolicy(_ policy: Policy) {
        let changed = AppGroup.withLock("policy") { () -> Bool in
            guard policy.updatedAt > (AppGroup.loadPolicy()?.updatedAt ?? .distantPast) else { return false }
            AppGroup.savePolicy(policy)
            return true
        }
        guard changed else { return }
        try? AppGroup.journal.append(.note("policy updated: \(policy.enabled ? "on" : "off"), \(policy.downtime.count) downtime, \(policy.limits.count) limits"))
        Enforcer.reconcile()
    }
}
