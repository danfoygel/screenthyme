import DeviceActivity
import Foundation
import ThymeCore

/// Capture (PLAN.md §13). Each total-use threshold wakes the extension: journal the fire, fetch Apple's per-app
/// data and record what changed, evaluate rules, keep the alarm registered, then a short best-effort upload.
/// Anything not uploaded here is sent by the app. Each callback ends by metering this process's energy use
/// (`EnergyMeter`), so parents can see what capture costs the kid's battery.
final class ThymeMonitorExtension: DeviceActivityMonitor {
    /// The extension's process may be suspended as soon as a callback returns.
    static let uploadWait: TimeInterval = 3

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        defer { EnergyMeter.record(.monitor, isCallback: true) }
        let entry = JournalEntry(kind: .threshold, activity: activity.rawValue, event: event.rawValue, at: Date())
        try? AppGroup.journal.append(entry)
        let config = SharedConfig.load()
        // Only total fires; anything else is a leftover registration from the old per-app ladders.
        guard let parsed = entry.parsedEvent, parsed.itemID == nil else { return }

        let sampled = config.kid.flatMap { kid in Sampler.isAuthorized ? Sampler.sampleBlocking(kid: kid) : nil }
        let wake = WakeObservation(at: entry.at, totalMinute: parsed.minute,
                                   itemSeconds: sampled?.itemSeconds ?? [:],
                                   intervalSeconds: sampled?.intervalSeconds ?? [:],
                                   newItems: sampled?.newItems.map(\.id) ?? [])
        // Wakes can overlap in separate processes: one read-modify-write of the day state at a time.
        let state = AppGroup.withLock("monitor-state") {
            var state = MonitorStateStore.load(day: DayKey(entry.at))
            if let kid = config.kid {
                let items = Dictionary(AppGroup.loadItems().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                let engine = RuleEngine(kidID: kid.id, kidName: kid.displayName, items: items)
                try? AppGroup.outbox.append(contentsOf: engine.process(wake, state: &state, rules: config.rules))
            } else {
                state.record(wake)
            }
            MonitorStateStore.save(state)
            return state
        }
        Roller.roll(after: parsed.minute, state: state)
        upload(config)
    }

    override func intervalDidStart(for activity: DeviceActivityName) {
        try? AppGroup.journal.append(JournalEntry(kind: .intervalStart, activity: activity.rawValue, at: Date()))
        Roller.intervalStarted()
        EnergyMeter.record(.monitor, isCallback: true)
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        try? AppGroup.journal.append(JournalEntry(kind: .intervalEnd, activity: activity.rawValue, at: Date()))
        EnergyMeter.record(.monitor, isCallback: true)
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
