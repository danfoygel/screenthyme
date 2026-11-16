import CloudKit
import DeviceActivity
import FamilyControls
import Foundation
import Observation
import ThymeCore

/// App-wide state and actions. A singleton so the app and scene delegates (pushes, share links) can reach it.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var config: SharedConfig
    let data = FamilyData()
    var message: String?
    private(set) var isRefreshing = false
    @ObservationIgnored private var isLaunching = false
    var lastUploadAt: Date?
    var lastHeartbeatAt: Date?
    var authorizationStatus = AuthorizationCenter.shared.authorizationStatus

    private init() {
        config = SharedConfig.load()
        // Rewrites the extension's slim copy, which older installs don't have yet.
        try? config.save()
    }

    var store: CloudStore? { config.family.map { CloudStore(family: $0) } }
    var isParent: Bool { config.role == .parent }
    var isKid: Bool { config.role == .kid }

    func update(_ change: (inout SharedConfig) -> Void) {
        var copy = config
        change(&copy)
        config = copy
        do { try copy.save() } catch { show(error) }
    }

    func show(_ error: any Error) {
        message = (error as? CKError).map { "iCloud: \($0.localizedDescription)" } ?? error.localizedDescription
    }

    // MARK: - Lifecycle

    /// Called by both the launch task and the scene becoming active; only one runs at a time.
    func launched() async {
        guard !isLaunching else { return }
        isLaunching = true
        defer { isLaunching = false }
        BackgroundRefresh.schedule()
        migrateToWakeAlarm()
        await ensureSubscriptions()
        switch config.role {
        case .kid:
            ensureMonitoring()
            await sampleNow()
            Enforcer.reconcile()
            TokenMatcher.ensureRegistered()
            await flush()
            await sendHeartbeat(.launch)
            await refresh()
            await KidSync.refreshIfDue(config: config, force: true)
        case .parent:
            await refresh()
            await handleTestRuleArguments()
            await PushDiagnostics.write(family: config.family, kids: data.sortedKids)
        case .unset:
            break
        }
    }

    func handlePush() async {
        await refresh()
        if isKid { await flush() }
    }

    func backgroundRefresh() async {
        if isKid {
            await sampleNow()
            await flush()
            await sendHeartbeat(.backgroundRefresh)
        }
        await refresh()
    }

    /// Fetches zone changes and reacts: kids pick up rules and answer pings; parents notify and check health.
    func refresh() async {
        guard let store, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let fullFetch = data.needsFullFetch
            if fullFetch { ChangeFetcher.resetToken(for: store) }
            let batch = try await ChangeFetcher.fetch(store: store)
            if fullFetch { data.fullFetchDone() }
            let newAlerts = data.ingest(batch)
            if isKid, let kid = config.kid {
                KidSync.saveRules(data.rules(for: kid.id), checkedAt: Date())
                if let policy = data.storedPolicy(for: kid.id) { KidSync.savePolicy(policy) }
                for grant in batch.grants where grant.kidID == kid.id { Enforcer.apply(grant) }
                if batch.pings.contains(where: { $0.kidID == kid.id && $0.at > (lastHeartbeatAt ?? .distantPast) }) {
                    await sendHeartbeat(.ping)
                }
            }
            if isParent {
                // The owner already got CloudKit's visible push for each alert.
                if config.family?.isOwner == false {
                    newAlerts.filter { Date().timeIntervalSince($0.at) < 3600 }.forEach(Notifier.post)
                }
                notifyHealthIssues()
            }
        } catch {
            show(error)
        }
    }

    // MARK: - Family

    func createFamily() async {
        do {
            let family = try await FamilyService.createFamily()
            update { $0.family = family }
            try await FamilyService.installSubscriptions(family: family, isParent: isParent)
            await publishKidIdentity()
        } catch {
            show(error)
        }
    }

    func acceptShare(_ metadata: CKShare.Metadata) async {
        do {
            let family = try await FamilyService.accept(metadata)
            update { $0.family = family }
            try await FamilyService.installSubscriptions(family: family, isParent: isParent)
            await publishKidIdentity()
            await refresh()
            message = "Joined the family."
        } catch {
            show(error)
        }
    }

    /// Once per process: the subscriptions this role needs. Saving them again is harmless; a phone that set up the
    /// family under another role (or whose earlier install failed) would otherwise miss alert banners.
    func ensureSubscriptions() async {
        guard !subscriptionsEnsured, let family = config.family else { return }
        do {
            try await FamilyService.installSubscriptions(family: family, isParent: isParent)
            subscriptionsEnsured = true
            PushDiagnostics.installError = nil
        } catch {
            PushDiagnostics.installError = "\(error)"
        }
    }

    /// Re-installs subscriptions, e.g. after switching roles in test mode.
    func reinstallSubscriptions() async {
        guard let family = config.family else { return }
        do { try await FamilyService.installSubscriptions(family: family, isParent: isParent) } catch { show(error) }
    }

    // MARK: - Roles (PLAN.md §7.1)

    func chooseRole(_ role: SharedConfig.Role, kidName: String? = nil) async {
        update { config in
            config.role = role
            if role == .kid, config.kid == nil {
                config.kid = Kid(displayName: kidName ?? "Kid", colorIndex: Int.random(in: 0..<6),
                                 deviceName: deviceName, isTest: config.testMode)
            }
        }
        if role == .parent { await Notifier.requestPermission() }
        await reinstallSubscriptions()
        await publishKidIdentity()
        await launched()
    }

    /// Switching identity stops monitoring and forgets this phone's apps, samples and day state: they belong to one kid.
    func switchKidIdentity(to kid: Kid) async {
        DeviceActivityCenter().stopMonitoring()
        update { config in
            config.kid = kid
            config.epoch = nil
            config.rules = []
        }
        for url in [AppGroup.itemsURL, AppGroup.rulesURL, AppGroup.snapshotURL, AppGroup.samples.url, AppGroup.newItems.url] {
            try? FileManager.default.removeItem(at: url)
        }
        MonitorStateStore.save(MonitorDayState(day: DayKey(Date())))
        await publishKidIdentity()
    }

    /// The kid record, every app seen so far and the monitoring epoch, which parents need to name things and check
    /// health. Called on joining or creating a family and from "Upload now".
    func publishKidIdentity() async {
        guard isKid, let kid = config.kid, let store else { return }
        let epochs = config.epoch.map { [$0] } ?? []
        let items = AppGroup.loadItems()
        do {
            try await store.save([kid])
            try await store.save(items)
            try await store.save(epochs)
            try await Uploader.resendTrackingStarts(config: config)
        } catch {
            show(error)
        }
        data.ingest(IngestBatch(kids: [kid], items: items, epochs: epochs))
    }

    private var deviceName: String {
        #if targetEnvironment(simulator)
        "Simulator"
        #else
        "iPhone"
        #endif
    }
}

@MainActor private var subscriptionsEnsured = false
