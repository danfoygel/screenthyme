import FamilyControls
import Foundation
import Synchronization
import ThymeCore

/// Keeps the scanned items current from Apple's own lists (`FamilyInventory`, PLAN.md §15.3): new apps and websites
/// get tokens and matches with no scan and no screenshots. Apps and categories come back at once. Websites take about
/// 10 s, and sometimes never come back, for every caller, for 20 minutes or more; so they're fetched at most hourly,
/// waited for 60 s, and a call that never returns keeps another from starting.
enum InventoryRefresh {
    struct State: Codable {
        var appsAt: Date?
        var websitesTriedAt: Date?
        var websitesAt: Date?
    }

    static var stateURL: URL { AppGroup.container.appending(path: "inventory.json") }
    static let websitesEvery: TimeInterval = 3600
    static let websitesTimeout: Duration = .seconds(60)
    private static let websitesInFlight = Mutex(false)

    static func load() -> State {
        AppGroup.load(State.self, from: stateURL) ?? State()
    }

    static func websitesDue(now: Date = Date()) -> Bool {
        load().websitesTriedAt.map { now.timeIntervalSince($0) >= websitesEvery } ?? true
    }

    /// Lists apps and categories and saves what changed; true if anything did.
    static func appsAndCategories(kid: Kid, now: Date = Date()) async -> Bool {
        let apps: [FamilyInventory.Entry], categories: [FamilyInventory.Entry]
        do {
            apps = try await fetchApps()
            categories = try await fetchCategories()
        } catch {
            try? AppGroup.journal.append(.note("inventory: apps failed: \(error)"))
            return false
        }
        saveExemptToken(from: apps)
        let changed = save(apps + categories, kid: kid, now: now, listed: "\(apps.count) apps, \(categories.count) categories")
        update { $0.appsAt = now }
        // Token pairing's last import: apps still unmatched now aren't installed, so they aren't counted as to match.
        AppGroup.save(TokenPairingView.State(importedAt: now), to: TokenPairingView.stateURL)
        return changed
    }

    /// Lists websites and saves what changed; true if anything did. False at once while an earlier call still waits.
    static func websites(kid: Kid, now: Date = Date()) async -> Bool {
        let started = websitesInFlight.withLock { inFlight in
            defer { inFlight = true }
            return !inFlight
        }
        guard started else { return false }
        update { $0.websitesTriedAt = now }
        let began = Date()
        switch await fetchWebsitesWithTimeout() {
        case nil:
            try? AppGroup.journal.append(.note("inventory: websites gave no answer in \(websitesTimeout)"))
            return false
        case .failure(let error):
            try? AppGroup.journal.append(.note("inventory: websites failed: \(error)"))
            return false
        case .success(let sites):
            let seconds = Int(Date().timeIntervalSince(began).rounded())
            let changed = save(sites, kid: kid, now: now, listed: "\(sites.count) websites in \(seconds) s")
            update { $0.websitesAt = now }
            return changed
        }
    }

    /// Merges the entries into the items (the sampler's lock: it rewrites items.json too); changed ones go to the outbox.
    private static func save(_ entries: [FamilyInventory.Entry], kid: Kid, now: Date, listed: String) -> Bool {
        AppGroup.withLock("sampler") {
            var items = AppGroup.loadItems()
            let outcome = FamilyInventory.apply(entries, to: &items, kid: kid.id, now: now)
            if !outcome.changed.isEmpty {
                AppGroup.saveItems(items)
                try? AppGroup.newItems.append(contentsOf: outcome.changed)
            }
            try? AppGroup.journal.append(.note("inventory: \(listed); \(outcome.tokens) new tokens, "
                + "\(outcome.pairing.added) matched, \(outcome.pairing.corrected) corrected, \(outcome.pairing.created) created"))
            return !outcome.changed.isEmpty
        }
    }

    /// ScreenThyme's own token, which Downtime and limits let through, when no scan picked it.
    private static func saveExemptToken(from apps: [FamilyInventory.Entry]) {
        let picked = AppGroup.load([Data].self, from: AppGroup.exemptTokensURL) ?? []
        guard picked.count != 1, let bundleID = Bundle.main.bundleIdentifier,
              let own = apps.first(where: { $0.identifier == bundleID }) else { return }
        AppGroup.save([own.tokenData], to: AppGroup.exemptTokensURL)
        try? AppGroup.journal.append(.note("inventory: ScreenThyme's own token saved"))
    }

    private static func update(_ change: (inout State) -> Void) {
        var state = load()
        change(&state)
        AppGroup.save(state, to: stateURL)
    }

    // MARK: Apple's lists (off the main actor: FamilyActivityData and its results aren't Sendable)

    private static func fetchApps() async throws -> [FamilyInventory.Entry] {
        try await FamilyActivityData.shared.installedApplications.compactMap { app in
            guard let id = app.bundleIdentifier, let token = app.token.flatMap(TokenCoding.encode) else { return nil }
            return FamilyInventory.Entry(kind: .app, identifier: id, tokenData: token)
        }
    }

    private static func fetchCategories() async throws -> [FamilyInventory.Entry] {
        try await FamilyActivityData.shared.activityCategories.compactMap { category in
            guard let name = category.localizedDisplayName, let token = category.token.flatMap(TokenCoding.encode)
            else { return nil }
            return FamilyInventory.Entry(kind: .category, identifier: name, tokenData: token)
        }
    }

    private static func fetchWebsites() async throws -> [FamilyInventory.Entry] {
        try await FamilyActivityData.shared.visitedWebDomains.compactMap { site in
            guard let domain = site.domain, let token = site.token.flatMap(TokenCoding.encode) else { return nil }
            return FamilyInventory.Entry(kind: .domain, identifier: domain, tokenData: token)
        }
    }

    /// The call can't be cancelled: past the timeout it's left waiting, and keeps `websitesInFlight` set until it ends.
    private static func fetchWebsitesWithTimeout() async -> Result<[FamilyInventory.Entry], any Error>? {
        await withCheckedContinuation { continuation in
            let once = Once(continuation)
            Task.detached {
                let result: Result<[FamilyInventory.Entry], any Error>
                do { result = .success(try await fetchWebsites()) } catch { result = .failure(error) }
                websitesInFlight.withLock { $0 = false }
                once.resume(result)
            }
            Task.detached {
                try? await Task.sleep(for: websitesTimeout)
                once.resume(nil)
            }
        }
    }
}

/// Resumes a continuation with whichever value comes first.
private final class Once<Value: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<Value, Never>?>

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume(_ value: Value) {
        continuation.withLock { $0.take() }?.resume(returning: value)
    }
}
