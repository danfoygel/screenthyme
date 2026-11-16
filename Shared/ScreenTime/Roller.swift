import DeviceActivity
import Foundation
import ThymeCore

/// The wake-up alarm (PLAN.md §13): one DeviceActivity activity whose total-use thresholds fire every
/// `RollingLadder.step` minutes of use, a few registered at a time. The extension re-registers when it gets near the
/// top, and starts over at midnight.
enum Roller {
    struct Activity: Codable, Sendable {
        var name: String
        var day: DayKey
        /// Highest total minute registered.
        var upTo = 0
    }

    static let ladder = RollingLadder()

    /// Daily, so the count resets at midnight.
    static var schedule: DeviceActivitySchedule {
        DeviceActivitySchedule(intervalStart: DateComponents(hour: 0, minute: 0),
                               intervalEnd: DateComponents(hour: 23, minute: 59), repeats: true)
    }

    static var url: URL { AppGroup.container.appending(path: "Rolling/activity.json") }

    // MARK: - App

    /// Replaces all monitoring for `epochID`, continuing after today's known total, and journals a tracking start
    /// (iOS replays already-passed thresholds as a catch-up).
    static func registerAll(epochID: UUID, kid: Kid, now: Date = Date()) throws -> LadderEpoch {
        let center = DeviceActivityCenter()
        // Every activity but the Enforcer's. Never an empty list: that stops everything.
        let old = center.activities.filter { !Enforcer.owns($0.rawValue) }
        if !old.isEmpty { center.stopMonitoring(old) }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let activity = Activity(name: RollingLadder.activityName(epochID: epochID), day: DayKey(now))
        try? AppGroup.journal.append(JournalEntry(kind: .trackingStart, activity: activity.name, at: now))
        try register(activity, after: MonitorStateStore.load(day: activity.day).totalMinute, center: center)
        let active = center.activities.map(\.rawValue)
        let events = center.events(for: DeviceActivityName(activity.name)).count
        try? AppGroup.journal.append(.note("registered \(activity.name): \(events) events, iOS reports \(active.count) active"))
        // A new authorization grant stopped the Enforcer's activities too.
        Enforcer.reconcile(now: now)
        return LadderEpoch(id: epochID, kidID: kid.id, startedAt: now, activityNames: [activity.name])
    }

    // MARK: - Extension

    /// After a fire: re-register with the next thresholds when running low.
    static func roll(after minute: Int, state: MonitorDayState) {
        AppGroup.withLock("roll") {
            guard var activity = load(), ladder.needsRefill(crossed: minute, registeredUpTo: activity.upTo) else { return }
            activity.day = state.day
            do {
                try register(activity, after: max(minute, state.totalMinute), center: DeviceActivityCenter())
            } catch {
                try? AppGroup.journal.append(.note("roll failed: \(error.localizedDescription)"))
            }
        }
    }

    /// A new interval: at midnight, start over. Our own re-registrations also start an interval; those find the
    /// activity already on today and do nothing.
    static func intervalStarted(now: Date = Date()) {
        AppGroup.withLock("roll") {
            let today = DayKey(now)
            guard var activity = load(), activity.day != today else { return }
            activity.day = today
            try? register(activity, after: 0, center: DeviceActivityCenter())
        }
    }

    // MARK: - Registration

    private static func register(_ activity: Activity, after minute: Int, center: DeviceActivityCenter) throws {
        var activity = activity
        let minutes = ladder.thresholds(after: minute)
        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        for minute in minutes {
            events[.init(EventName.total(minute: minute))] = DeviceActivityEvent(
                threshold: DateComponents(minute: minute), includesPastActivity: true)
        }
        try center.startMonitoring(DeviceActivityName(activity.name), during: schedule, events: events)
        activity.upTo = minutes.last ?? minute
        try JSONEncoder.thyme.encode(activity).write(to: url, options: .atomic)
    }

    static func load() -> Activity? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.thyme.decode(Activity.self, from: data)
    }
}
