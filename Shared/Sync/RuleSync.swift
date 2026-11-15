import CloudKit
import Foundation
import ThymeCore

/// Keeps a kid phone's rules current without relying on silent pushes, which iOS rations: the monitor extension
/// fetches the kid's `RuleSet` record by name at most every `interval` (PLAN.md §14).
enum RuleSync {
    static let interval: TimeInterval = 10 * 60

    static func refreshIfDue(config: SharedConfig, now: Date = Date()) async {
        guard let family = config.family, let kid = config.kid else { return }
        let local = AppGroup.loadRules()
        guard now.timeIntervalSince(local?.checkedAt ?? .distantPast) >= interval else { return }
        let store = CloudStore(family: family)
        let id = CKRecord.ID(recordName: "\(RuleSet.recordType).\(kid.id.uuidString)", zoneID: store.zoneID)
        do {
            let record = try await store.database.record(for: id)
            guard let set = RuleSet.decode(record) else { return }
            let saved = set.updatedAt.formatted(.iso8601)
            try? AppGroup.journal.append(.note("rule sync: \(set.rules.count) rules, saved \(saved)"))
            save(set.rules, checkedAt: now)
        } catch let error as CKError where error.code == .unknownItem {
            // No parent has saved rules since RuleSets were introduced: keep what we have.
            try? AppGroup.journal.append(.note("rule sync: no RuleSet yet"))
            save(local?.rules ?? config.rules, checkedAt: now)
        } catch {
            try? AppGroup.journal.append(.note("rule sync failed: \(error)"))
        }
    }

    /// Writes the rules if they changed; always records the check.
    static func save(_ rules: [Rule], checkedAt: Date) {
        AppGroup.withLock("rules") {
            let current = AppGroup.loadRules()
            if let current, Set(current.rules) != Set(rules) {
                try? AppGroup.journal.append(.note("rules updated: \(rules.count)"))
            }
            AppGroup.saveRules(LocalRules(rules: rules, checkedAt: checkedAt))
        }
    }
}
