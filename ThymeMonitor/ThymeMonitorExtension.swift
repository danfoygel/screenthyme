import DeviceActivity
import Foundation
// Only for DeviceActivityData.activitySegments (declared in the SwiftUI overlay), used by the S4 probe.
import SwiftUI
import ThymeCore

/// Capture (PLAN.md §4.1): journal first, then rules and the next rolling thresholds, then a short best-effort
/// upload. Anything not uploaded here is sent by the app's backlog flush. Each callback ends by metering this
/// process's energy use (`EnergyMeter`), so parents can see what capture costs the kid's battery.
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
            if parsed.itemID == nil, parsed.minute % 5 == 0 {
                probeDataAccess(minute: parsed.minute)
            }
        }
        upload(config)
        EnergyMeter.record(.monitor, isCallback: true)
    }

    /// S4 probe: can the extension read the iOS 26.4 activity data, and how fast? Result goes to the journal.
    private func probeDataAccess(minute: Int) {
        let done = DispatchSemaphore(value: 0)
        let started = Date()
        Task.detached {
            let text: String
            do {
                let today = Calendar.current.dateInterval(of: .day, for: Date())!
                var apps = 0
                var seconds: TimeInterval = 0
                for try await data in DeviceActivityData.activityData(filteredBy: DeviceActivityFilter(segment: .daily(during: today))) {
                    for await segment in data.activitySegments {
                        seconds += segment.totalActivityDuration
                        for await category in segment.categories {
                            for await _ in category.applications { apps += 1 }
                        }
                    }
                }
                text = "S4 probe at total \(minute): ok, \(Int(seconds / 60)) min, \(apps) app rows"
            } catch {
                text = "S4 probe at total \(minute): \(error)"
            }
            try? AppGroup.journal.append(.note(text + String(format: " (%.2f s)", Date().timeIntervalSince(started))))
            done.signal()
        }
        if done.wait(timeout: .now() + 5) == .timedOut {
            try? AppGroup.journal.append(.note("S4 probe at total \(minute): timed out after 5 s"))
        }
    }

    override func intervalDidStart(for activity: DeviceActivityName) {
        try? AppGroup.journal.append(JournalEntry(kind: .intervalStart, activity: activity.rawValue, at: Date()))
        Roller.intervalStarted(activityName: activity.rawValue)
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
