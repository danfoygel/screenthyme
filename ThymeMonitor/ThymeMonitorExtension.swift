import DeviceActivity
import Foundation
import ThymeCore

/// Capture (PLAN.md §13). Each total-use threshold wakes the extension: journal the fire, fetch Apple's per-app
/// data and record what changed, evaluate rules, keep the alarm registered, enforce (§15), then a short best-effort
/// upload (and a policy and rules check). Downtime intervals and limit fires also enforce; token-match fires learn
/// which app a scanned token is (§15.5).
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
        // By the event's name too: the first `tm` fires on a phone went the wake alarm's way (cause unknown).
        if event.rawValue.hasPrefix(TokenMatcher.eventPrefix) || activity.rawValue == TokenMatcher.activity.rawValue {
            try? AppGroup.journal.append(.note("token match fired: \(event.rawValue)"))
            let config = SharedConfig.load()
            if let kid = config.kid { TokenMatcher.fired(event.rawValue, kid: kid) }
            upload(config)
            return
        }
        let entry = JournalEntry(kind: .threshold, activity: activity.rawValue, event: event.rawValue, at: Date())
        try? AppGroup.journal.append(entry)
        let config = SharedConfig.load()
        // Only total fires; anything else is a leftover registration from the old per-app ladders.
        guard let parsed = entry.parsedEvent, parsed.itemID == nil else { return }

        // No authorization check: `authorizationStatus` is unreliable in the extension (sampling never ran behind
        // it). A phone without data access fails the fetch, which `sampleBlocking` journals.
        let sampled = config.kid.flatMap { Sampler.sampleBlocking(kid: $0) }
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
                try? AppGroup.outbox.append(contentsOf: engine.process(wake, state: &state, rules: config.currentRules))
            } else {
                state.record(wake)
            }
            MonitorStateStore.save(state)
            return state
        }
        Roller.roll(after: parsed.minute, state: state)
        Enforcer.reconcile(now: entry.at)
        upload(config)
    }

    override func intervalDidStart(for activity: DeviceActivityName) {
        defer { EnergyMeter.record(.monitor, isCallback: true) }
        let name = activity.rawValue
        if name == TokenMatcher.activity.rawValue {
            TokenMatcher.intervalStarted()
            return
        }
        if name.hasPrefix(Enforcer.downtimePrefix) || name.hasPrefix(Enforcer.limitPrefix) {
            try? AppGroup.journal.append(.note("interval start: \(name)"))
        } else {
            try? AppGroup.journal.append(JournalEntry(kind: .intervalStart, activity: name, at: Date()))
            Roller.intervalStarted()
        }
        // Downtime starting, or a new day for limits.
        Enforcer.reconcile()
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        defer { EnergyMeter.record(.monitor, isCallback: true) }
        let name = activity.rawValue
        if name.hasPrefix(Enforcer.downtimePrefix) {
            try? AppGroup.journal.append(.note("interval end: \(name)"))
            Enforcer.reconcile(endingWindows: Enforcer.endingWindow(for: name).map { [$0] } ?? [])
        } else if !name.hasPrefix(Enforcer.limitPrefix), name != TokenMatcher.activity.rawValue {
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
