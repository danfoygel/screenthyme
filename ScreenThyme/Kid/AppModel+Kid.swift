import DeviceActivity
import FamilyControls
import Foundation
import ThymeCore
import UIKit

/// Kid-side actions: authorization, the wake alarm, sampling, uploads, heartbeats (PLAN.md §4.7, §13).
extension AppModel {
    func requestAuthorization() async {
        var failure: (any Error)?
        do {
            let member: FamilyControlsMember = config.authMode == .child ? .child : .individual
            try await AuthorizationCenter.shared.requestAuthorization(for: member)
        } catch {
            failure = error
        }
        authorizationStatus = AuthorizationCenter.shared.authorizationStatus
        // iOS can report authorizationConflict (another Screen Time app on the phone) yet still approve us.
        if let failure, !isAuthorized {
            show(failure)
        }
        // A new grant (e.g. upgrading to data access) makes iOS stop every activity (PLAN.md §13): start again.
        if isAuthorized, config.epoch != nil {
            await startMonitoring()
        }
        await sendHeartbeat(.manual)
    }

    var isAuthorized: Bool {
        authorizationStatus == .approved || authorizationStatus == .approvedWithDataAccess
    }

    /// Capture needs Apple's per-app data (iOS 26.4's data access), not just plain approval.
    var hasDataAccess: Bool {
        authorizationStatus == .approvedWithDataAccess
    }

    var authorizationLabel: String {
        switch authorizationStatus {
        case .approvedWithDataAccess: "approved with data access"
        case .approved: "approved"
        case .denied: "denied"
        case .notDetermined: "notDetermined"
        @unknown default: "unknown"
        }
    }

    var monitoringLabel: String {
        guard let epoch = config.epoch else { return "not started" }
        let active = Set(DeviceActivityCenter().activities.map(\.rawValue))
        return epoch.activityNames.allSatisfy(active.contains) ? "on" : "stopped (open the app to restart)"
    }

    /// Registers the wake alarm for a (new or current) epoch and publishes it. Off the main thread: iOS can take
    /// seconds to register.
    func startMonitoring() async {
        guard let kid = config.kid else { return }
        // A kid switching away mid-registration suspended the app once, leaving the alarm with no state.
        let background = UIApplication.shared.beginBackgroundTask(withName: "register wake alarm")
        defer { UIApplication.shared.endBackgroundTask(background) }
        let epochID = config.epoch?.id ?? UUID()
        do {
            let epoch = try await Task.detached(priority: .userInitiated) {
                try Roller.registerAll(epochID: epochID, kid: kid)
            }.value
            update { $0.epoch = epoch }
            Task {
                do { try await store?.save([epoch]) } catch { show(error) }
                data.ingest(IngestBatch(epochs: [epoch]))
            }
        } catch {
            try? AppGroup.journal.append(.note("registration failed: \(error)"))
            show(error)
        }
    }

    /// Re-registers if iOS dropped the alarm (PLAN.md §4.7). At most every 10 minutes: each registration replays
    /// today's passed thresholds.
    func ensureMonitoring() async {
        guard let epoch = config.epoch else { return }
        let active = Set(DeviceActivityCenter().activities.map(\.rawValue))
        // Running without its state, the alarm never rolls or restarts at midnight. A state from an earlier day means
        // the midnight restart didn't happen: the alarm is at yesterday's thresholds.
        guard !Set(epoch.activityNames).isSubset(of: active) || Roller.load()?.day != DayKey(Date()) else { return }
        let key = "lastEnsureMonitoring"
        if let last = UserDefaults.standard.object(forKey: key) as? Date, Date().timeIntervalSince(last) < 600 { return }
        UserDefaults.standard.set(Date(), forKey: key)
        try? AppGroup.journal.append(.note("re-registering: alarm or its state missing, or from an earlier day"))
        await startMonitoring()
    }

    /// Phones registered with per-app ladders (before §13) move to the single wake alarm.
    func migrateToWakeAlarm() async {
        guard let epoch = config.epoch,
              epoch.activityNames != [RollingLadder.activityName(epochID: epoch.id)] else { return }
        await startMonitoring()
    }

    func stopMonitoring() {
        DeviceActivityCenter().stopMonitoring()
        update { $0.epoch = nil }
    }

    /// Takes a sample from the app as well (on launch, background refresh, Upload now): fresher data between wakes.
    func sampleNow() async {
        guard isKid, hasDataAccess, let kid = config.kid else { return }
        do { _ = try await Sampler.sample(kid: kid) } catch { show(error) }
    }

    func flush() async {
        guard isKid, config.family != nil else { return }
        EnergyMeter.record(.app, isCallback: false)
        do {
            let result = try await Uploader.flush(config: config)
            lastUploadAt = Date()
            if result.fires > 0 || result.samples > 0 || result.alerts > 0 {
                await refresh()
            }
        } catch {
            showUnlessOffline(error)
        }
    }

    func sendHeartbeat(_ source: HeartbeatSource) async {
        guard isKid, let kid = config.kid, let store else { return }
        await DevicePermissions.refresh()
        guard let heartbeat = makeHeartbeat(source) else { return }
        // Today's energy goes with every heartbeat, so a ping always brings fresh numbers.
        EnergyMeter.record(.app, isCallback: false)
        let energy = EnergyMeter.report(kid: kid, day: DayKey(Date()))
        do {
            try await store.save(records: [heartbeat.record(in: store.zoneID), energy.record(in: store.zoneID)])
            EnergyMeter.markUploaded([energy])
            lastHeartbeatAt = heartbeat.at
        } catch {
            showUnlessOffline(error)
        }
    }

    /// This phone's state now. One record per kid, overwritten: parents only need the latest.
    func makeHeartbeat(_ source: HeartbeatSource) -> Heartbeat? {
        guard isKid, let kid = config.kid else { return nil }
        authorizationStatus = AuthorizationCenter.shared.authorizationStatus
        UIDevice.current.isBatteryMonitoringEnabled = true
        let batteryLevel = UIDevice.current.batteryLevel
        return Heartbeat(id: Replay.stableUUID("heartbeat", kid.id.uuidString), kidID: kid.id, at: Date(),
                         source: source, authStatus: authorizationLabel,
                         activeActivities: DeviceActivityCenter().activities.map(\.rawValue),
                         expectedActivities: config.epoch?.activityNames ?? [],
                         appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
                         backlogCount: Uploader.backlogCount(),
                         lastFireAt: AppGroup.journal.lastThresholdAt(),
                         batteryLevel: batteryLevel >= 0 ? Double(batteryLevel) : nil,
                         backgroundRefresh: DevicePermissions.backgroundRefresh,
                         cellularData: DevicePermissions.cellularData,
                         bluetooth: DevicePermissions.bluetooth,
                         localNetwork: DevicePermissions.localNetwork,
                         iCloud: DevicePermissions.iCloud,
                         lowPowerMode: DevicePermissions.lowPowerMode,
                         lastTokenPairing: TokenPairingView.lastImport())
    }

    /// A day of this phone's capture as a trace file, for the replay tool and test fixtures (PLAN.md §7.2).
    func exportTrace(day: DayKey) throws -> URL {
        guard let kid = config.kid else { throw CocoaError(.featureUnsupported) }
        let trace = Trace(kid: kid, day: day, items: AppGroup.loadItems(), epoch: config.epoch,
                          entries: AppGroup.journal.entries(on: day),
                          samples: AppGroup.samples.readAll().filter { $0.day == day })
        let url = URL.temporaryDirectory.appending(path: "trace-\(kid.displayName)-\(day).json")
        try trace.encoded().write(to: url, options: .atomic)
        return url
    }
}

extension Enforcer {
    /// Enforcing registers DeviceActivity schedules: synchronous calls into Apple's usage-tracking service that can
    /// hang for more than 10 s. On the app's main thread iOS then kills the app (watchdog 0x8badf00d, twice on the kid's
    /// phone on Nov 15, 2026), so the app enforces through this. The App Group lock makes it safe on any thread.
    static func offMain(_ work: @escaping @Sendable () -> Void) async {
        await Task.detached(priority: .userInitiated, operation: work).value
    }
}
