import FamilyControls
import Foundation
import Synchronization
import ThymeCore

/// Keeps the scanned items current from Apple's own lists (`FamilyInventory`, PLAN.md §15.3): new apps and websites
/// get tokens and matches with no scan and no screenshots. Apple's service behind them can stop answering, for every
/// caller, for 20 minutes or more (websites most often, but apps too), and a call can't be cancelled. So nothing waits
/// on a list longer than its timeout, a list still waiting keeps another call to it from starting, and the app never
/// waits on a refresh (`AppModel.refreshInventory`). Websites take about 10 s even when well, so they're listed at
/// most hourly; apps and categories, at once when well, at every refresh.
enum InventoryRefresh {
    struct State: Codable {
        var appsAt: Date?
        var websitesTriedAt: Date?
        var websitesAt: Date?
    }

    static var stateURL: URL { AppGroup.container.appending(path: "inventory.json") }
    static let websitesEvery: TimeInterval = 3600

    static func load() -> State {
        AppGroup.load(State.self, from: stateURL) ?? State()
    }

    static func websitesDue(now: Date = Date()) -> Bool {
        load().websitesTriedAt.map { now.timeIntervalSince($0) >= websitesEvery } ?? true
    }

    /// Lists apps and categories and saves what changed; true if anything did.
    static func appsAndCategories(kid: Kid, now: Date = Date()) async -> Bool {
        guard let apps = await entries(.apps), let categories = await entries(.categories) else { return false }
        saveExemptToken(from: apps)
        let changed = save(apps + categories, kid: kid, now: now, listed: "\(apps.count) apps, \(categories.count) categories")
        update { $0.appsAt = now }
        // Token pairing's last import: apps still unmatched now aren't installed, so they aren't counted as to match.
        AppGroup.save(TokenPairingView.State(importedAt: now), to: TokenPairingView.stateURL)
        return changed
    }

    /// Lists websites and saves what changed; true if anything did.
    static func websites(kid: Kid, now: Date = Date()) async -> Bool {
        update { $0.websitesTriedAt = now }
        let began = Date()
        guard let sites = await entries(.websites) else { return false }
        let seconds = Int(Date().timeIntervalSince(began).rounded())
        let changed = save(sites, kid: kid, now: now, listed: "\(sites.count) websites in \(seconds) s")
        update { $0.websitesAt = now }
        return changed
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

    // MARK: Apple's lists

    private enum List: String, Sendable {
        case apps, categories, websites

        var timeout: Duration { self == .websites ? .seconds(60) : .seconds(20) }
    }

    private static let waiting = Mutex<Set<List>>([])

    /// One list, or nil (journaled) if it failed, gave no answer in time, or is still waiting from an earlier call.
    private static func entries(_ list: List) async -> [FamilyInventory.Entry]? {
        guard waiting.withLock({ $0.insert(list).inserted }) else {
            try? AppGroup.journal.append(.note("inventory: \(list.rawValue) still waiting from an earlier call"))
            return nil
        }
        switch await answer(list) {
        case nil:
            try? AppGroup.journal.append(.note("inventory: \(list.rawValue) gave no answer in \(list.timeout)"))
            return nil
        case .failure(let error):
            try? AppGroup.journal.append(.note("inventory: \(list.rawValue) failed: \(error)"))
            return nil
        case .success(let entries):
            return entries
        }
    }

    /// The call can't be cancelled: past the timeout it's left waiting, and keeps its list in `waiting` until it ends.
    private static func answer(_ list: List) async -> Result<[FamilyInventory.Entry], any Error>? {
        await withCheckedContinuation { continuation in
            let once = Once(continuation)
            Task.detached {
                let result: Result<[FamilyInventory.Entry], any Error>
                do { result = .success(try await fetch(list)) } catch { result = .failure(error) }
                _ = waiting.withLock { $0.remove(list) }
                once.resume(result)
            }
            Task.detached {
                try? await Task.sleep(for: list.timeout)
                once.resume(nil)
            }
        }
    }

    /// Off the main actor: FamilyActivityData and its results aren't Sendable, so only entries come back.
    private static func fetch(_ list: List) async throws -> [FamilyInventory.Entry] {
        let data = FamilyActivityData.shared
        switch list {
        case .apps:
            return try await data.installedApplications.compactMap { app in
                guard let id = app.bundleIdentifier, let token = app.token.flatMap(TokenCoding.encode) else { return nil }
                return FamilyInventory.Entry(kind: .app, identifier: id, tokenData: token)
            }
        case .categories:
            return try await data.activityCategories.compactMap { category in
                guard let name = category.localizedDisplayName, let token = category.token.flatMap(TokenCoding.encode)
                else { return nil }
                return FamilyInventory.Entry(kind: .category, identifier: name, tokenData: token)
            }
        case .websites:
            return try await data.visitedWebDomains.compactMap { site in
                guard let domain = site.domain, let token = site.token.flatMap(TokenCoding.encode) else { return nil }
                return FamilyInventory.Entry(kind: .domain, identifier: domain, tokenData: token)
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
