import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings
import ThymeCore

/// Kid-side actions: authorization, scans, ladder registration, uploads, heartbeats (PLAN.md §4.1, §4.7).
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
        await sendHeartbeat(.manual)
    }

    /// Either kind of approval: plain, or with the iOS 26.4 data-access option (PLAN.md test 4).
    var isAuthorized: Bool {
        authorizationStatus == .approved || authorizationStatus == .approvedWithDataAccess
    }

    var authorizationLabel: String {
        switch authorizationStatus {
        case .approved, .approvedWithDataAccess: "approved"
        case .denied: "denied"
        case .notDetermined: "notDetermined"
        @unknown default: "unknown"
        }
    }

    /// Turns a "select all" picker result into tracked items, keeping the ids of apps seen in earlier scans,
    /// then registers a new epoch of ladders and retires the old one.
    func applyScan(_ selection: FamilyActivitySelection) async {
        guard let kid = config.kid else { return }
        let epochID = UUID()
        var items = config.items
        var nextOrdinal = (items.map(\.ordinal).max() ?? 0) + 1
        var seen = Set<UUID>()

        func upsert(kind: ItemKind, data: Data?, matches: (TrackedItem) -> Bool) {
            if let index = items.firstIndex(where: { $0.kind == kind && matches($0) }) {
                items[index].tokenData = data
                items[index].active = true
                seen.insert(items[index].id)
            } else {
                let item = TrackedItem(kidID: kid.id, kind: kind, tokenData: data, ordinal: nextOrdinal,
                                       firstSeenEpoch: epochID)
                nextOrdinal += 1
                items.append(item)
                seen.insert(item.id)
            }
        }
        for token in selection.applicationTokens {
            upsert(kind: .app, data: TokenCoding.encode(token)) { TokenCoding.application($0.tokenData) == token }
        }
        for token in selection.webDomainTokens {
            upsert(kind: .domain, data: TokenCoding.encode(token)) { TokenCoding.webDomain($0.tokenData) == token }
        }
        for token in selection.categoryTokens {
            upsert(kind: .category, data: TokenCoding.encode(token)) { TokenCoding.category($0.tokenData) == token }
        }
        for index in items.indices where !seen.contains(items[index].id) {
            items[index].active = false
        }

        do {
            let epoch = try Roller.registerAll(epochID: epochID, kid: kid, items: items.filter(\.active))
            update { config in
                config.items = items
                config.epoch = epoch
            }
            message = "Tracking \(scanSummary(items)) in \(epoch.activityNames.count) rolling schedules."
            if let store {
                try await store.save(items)
                try await store.save([epoch])
            }
            data.ingest(IngestBatch(items: items, epochs: [epoch]))
            await sendHeartbeat(.manual)
        } catch {
            message = "Scan returned \(scanSummary(items)). \(error.localizedDescription)"
        }
    }

    private func scanSummary(_ items: [TrackedItem]) -> String {
        let active = items.filter(\.active)
        let count = { (kind: ItemKind) in active.filter { $0.kind == kind }.count }
        return "\(count(.app)) apps, \(count(.domain)) websites, \(count(.category)) categories"
    }

    /// Re-registers the current epoch if iOS dropped any of its schedules (PLAN.md §4.7).
    func ensureMonitoring() {
        guard let epoch = config.epoch, let kid = config.kid else { return }
        let active = Set(DeviceActivityCenter().activities.map(\.rawValue))
        let missing = epoch.activityNames.filter { !active.contains($0) }
        guard !missing.isEmpty else { return }
        // Every registration replays today's thresholds; don't retry more than every 10 minutes.
        let key = "lastEnsureMonitoring"
        if let last = UserDefaults.standard.object(forKey: key) as? Date, Date().timeIntervalSince(last) < 600 { return }
        UserDefaults.standard.set(Date(), forKey: key)
        let names = missing.map { String($0.split(separator: ".").last ?? "") }
        try? AppGroup.journal.append(.note("re-registering; missing \(missing.count)/\(epoch.activityNames.count): \(names.joined(separator: ","))"))
        do {
            _ = try Roller.registerAll(epochID: epoch.id, kid: kid, items: config.items.filter(\.active))
        } catch {
            show(error)
        }
    }

    /// Scans registered before rolling ladders hold thousands of events, which Apple's Screen Time daemon can't
    /// handle on smaller phones (PLAN.md §11). Re-registers them as rolling, whatever this device's current role.
    func migrateToRollingLadders() {
        guard let epoch = config.epoch, let kid = config.kid,
              !epoch.activityNames.contains(RollingLadder.totalActivity(epochID: epoch.id)) else { return }
        do {
            let rolling = try Roller.registerAll(epochID: epoch.id, kid: kid, items: config.items.filter(\.active))
            update { $0.epoch = rolling }
        } catch {
            show(error)
        }
    }

    func stopMonitoring() {
        DeviceActivityCenter().stopMonitoring()
        update { $0.epoch = nil }
    }

    func saveNicknames(_ nicknames: [UUID: String]) async {
        update { config in
            for index in config.items.indices {
                guard let name = nicknames[config.items[index].id] else { continue }
                config.items[index].nickname = name.isEmpty ? nil : name
            }
        }
        do { try await store?.save(config.items) } catch { show(error) }
        data.ingest(IngestBatch(items: config.items))
    }

    func flush() async {
        guard isKid, config.family != nil else { return }
        do {
            let result = try await Uploader.flush(config: config)
            lastUploadAt = Date()
            if result.fires > 0 || result.alerts > 0 {
                await refresh()
            }
        } catch {
            show(error)
        }
    }

    func sendHeartbeat(_ source: HeartbeatSource) async {
        guard isKid, let kid = config.kid, let store else { return }
        authorizationStatus = AuthorizationCenter.shared.authorizationStatus
        // One record per kid, overwritten: parents only need the latest.
        let heartbeat = Heartbeat(id: Replay.stableUUID("heartbeat", kid.id.uuidString), kidID: kid.id, at: Date(),
                                  source: source, authStatus: authorizationLabel,
                                  activeActivities: DeviceActivityCenter().activities.map(\.rawValue),
                                  expectedActivities: config.epoch?.activityNames ?? [],
                                  appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
                                  backlogCount: Uploader.backlogCount(),
                                  lastFireAt: AppGroup.journal.lastThresholdAt())
        do {
            try await store.save([heartbeat])
            lastHeartbeatAt = heartbeat.at
        } catch {
            show(error)
        }
    }

    /// Today's journal as a trace file, for the replay tool and test fixtures (PLAN.md §7.2).
    func exportTrace(day: DayKey) throws -> URL {
        guard let kid = config.kid else { throw CocoaError(.featureUnsupported) }
        let trace = Trace(kid: kid, day: day, items: config.items, epoch: config.epoch,
                          entries: AppGroup.journal.entries(on: day))
        let url = URL.temporaryDirectory.appending(path: "trace-\(kid.displayName)-\(day).json")
        try trace.encoded().write(to: url, options: .atomic)
        return url
    }
}
