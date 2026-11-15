import DeviceActivity
import Foundation
import ThymeCore

/// Capture (PLAN.md §4.1): journal first, then rules and the next rolling thresholds, then a short best-effort
/// upload. Anything not uploaded here is sent by the app's backlog flush.
final class ThymeMonitorExtension: DeviceActivityMonitor {
    /// The extension's process may be suspended as soon as a callback returns.
    static let uploadWait: TimeInterval = 3

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        let entry = JournalEntry(kind: .threshold, activity: activity.rawValue, event: event.rawValue, at: Date())
        try? AppGroup.journal.append(entry)

        let config = SharedConfig.loadForMonitor()
        if let parsed = entry.parsedEvent {
            // Fires arrive in bursts, possibly in parallel processes: one read-modify-write of the day state at a time.
            let state = AppGroup.withLock("monitor-state") {
                var state = MonitorStateStore.load(day: DayKey(entry.at))
                if let kid = config.kid {
                    let items = Dictionary(uniqueKeysWithValues: config.items.map { ($0.id, $0) })
                    let engine = RuleEngine(kidID: kid.id, kidName: kid.displayName, items: items)
                    let alerts = engine.process(parsed, at: entry.at, state: &state, rules: config.rules)
                    try? AppGroup.outbox.append(contentsOf: alerts)
                } else {
                    state.record(parsed, at: entry.at)
                }
                MonitorStateStore.save(state)
                return state
            }
            Roller.roll(activityName: activity.rawValue, fire: parsed, state: state)
        }
        upload(config)
    }

    override func intervalDidStart(for activity: DeviceActivityName) {
        try? AppGroup.journal.append(JournalEntry(kind: .intervalStart, activity: activity.rawValue, at: Date()))
        Roller.intervalStarted(activityName: activity.rawValue)
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        try? AppGroup.journal.append(JournalEntry(kind: .intervalEnd, activity: activity.rawValue, at: Date()))
    }

    private func upload(_ config: SharedConfig) {
        guard config.family != nil else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            _ = try? await Uploader.flush(config: config, days: 2)
            done.signal()
        }
        _ = done.wait(timeout: .now() + Self.uploadWait)
    }
}
