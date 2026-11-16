import DeviceActivity
import Foundation
import ThymeCore

/// Capture (PLAN.md §13). Each total-use threshold wakes the extension: journal the fire, fetch Apple's per-app
/// data and record what changed, evaluate rules, keep the alarm registered, enforce (§15), then a short best-effort
/// upload (and a policy and rules check). Downtime intervals, limit fires and the end of a "one more minute" also
/// enforce.
/// Anything not uploaded here is sent by the app. Each callback ends by metering this process's energy use
/// (`EnergyMeter`), so parents can see what capture costs the kid's battery.
final class ThymeMonitorExtension: DeviceActivityMonitor {
    /// The extension's process may be suspended as soon as a callback returns.
    static let uploadWait: TimeInterval = 3

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        defer { EnergyMeter.record(.monitor, isCallback: true) }
        if activity.rawValue.hasPrefix(Enforcer.limitPrefix) {
            try? AppGroup.journal.append(.note("limit reached: \(event.rawValue)"))
            Enforcer.limitFired(event.rawValue)
            return
        }
        let at = Date()
        let minute: Int
        switch Roller.observe(event.rawValue, at: at) {
        case let .use(ours):
            minute = ours
        case .calibration:
            return
        case .unknown:
            // A leftover registration from the old per-app ladders.
            try? AppGroup.journal.append(JournalEntry(kind: .threshold, activity: activity.rawValue, event: event.rawValue, at: at))
            return
        }
        // In our minutes, which differ from the event's after iOS restarted today's count lower (PLAN.md §16).
        let entry = JournalEntry(kind: .threshold, activity: activity.rawValue, event: EventName.total(minute: minute), at: at)
        try? AppGroup.journal.append(entry)
        let config = SharedConfig.load()

        // No authorization check: `authorizationStatus` is unreliable in the extension (sampling never ran behind
        // it). A phone without data access fails the fetch, which `sampleBlocking` reports.
        let sample = config.kid.map { Sampler.sampleBlocking(kid: $0) }
        let sampled = sample?.result
        let wake = WakeObservation(at: entry.at, totalMinute: minute,
                                   itemSeconds: sampled?.itemSeconds ?? [:],
                                   intervalSeconds: sampled?.intervalSeconds ?? [:],
                                   newItems: sampled?.newItems.map(\.id) ?? [])
        // Wakes can overlap in separate processes: one read-modify-write of the day state at a time.
        let state = AppGroup.withLock("monitor-state") {
            var state = MonitorStateStore.load(day: DayKey(entry.at))
            if let kid = config.kid {
                let items = Dictionary(AppGroup.loadItems().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                let engine = RuleEngine(kidID: kid.id, kidName: kid.displayName, items: items)
                var alerts = engine.process(wake, state: &state, rules: config.currentRules)
                let hasAccess: Bool? = sampled != nil ? true : sample?.unauthorized == true ? false : nil
                if let lost = engine.accessAlert(hasAccess: hasAccess, at: entry.at, state: &state) {
                    alerts.append(lost)
                    try? AppGroup.journal.append(.note("alert: no data access"))
                }
                try? AppGroup.outbox.append(contentsOf: alerts)
            } else {
                state.record(wake)
            }
            MonitorStateStore.save(state)
            return state
        }
        Roller.roll(after: minute, state: state)
        Enforcer.reconcile(now: entry.at)
        upload(config)
    }

    override func intervalDidStart(for activity: DeviceActivityName) {
        defer { EnergyMeter.record(.monitor, isCallback: true) }
        let name = activity.rawValue
        if name == Enforcer.extraMinuteActivity {
            // Called back at once when the shield action extension registers it, while that extension waits.
            // Re-applying here wrote ManagedSettings until iOS killed the extension (31 s; PLAN.md §15.5).
            try? AppGroup.journal.append(.note("interval start: \(name)"))
            return
        }
        if Enforcer.owns(name) {
            try? AppGroup.journal.append(.note("interval start: \(name)"))
        } else {
            try? AppGroup.journal.append(JournalEntry(kind: .intervalStart, activity: name, at: Date()))
            Roller.intervalStarted()
        }
        // Downtime starting, or a new day for limits.
        Enforcer.reconcile()
    }

    /// The extra-minute alarm is an end warning (schedules last at least 15 minutes).
    override func intervalWillEndWarning(for activity: DeviceActivityName) {
        defer { EnergyMeter.record(.monitor, isCallback: true) }
        guard activity.rawValue == Enforcer.extraMinuteActivity else { return }
        try? AppGroup.journal.append(.note("one more minute is up"))
        Enforcer.endExtraMinutes()
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        defer { EnergyMeter.record(.monitor, isCallback: true) }
        let name = activity.rawValue
        if name.hasPrefix(Enforcer.downtimePrefix) {
            try? AppGroup.journal.append(.note("interval end: \(name)"))
            Enforcer.reconcile(endingWindows: Enforcer.endingWindow(for: name).map { [$0] } ?? [])
        } else if name == Enforcer.extraMinuteActivity {
            Enforcer.endExtraMinutes()
        } else if !Enforcer.owns(name) {
            try? AppGroup.journal.append(JournalEntry(kind: .intervalEnd, activity: name, at: Date()))
        }
    }

    private func upload(_ config: SharedConfig) {
        guard config.family != nil else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            async let rules: Void = KidSync.refreshIfDue(config: config)
            _ = try? await Uploader.flush(config: config, days: 2)
            await rules
            done.signal()
        }
        _ = done.wait(timeout: .now() + Self.uploadWait)
    }
}
