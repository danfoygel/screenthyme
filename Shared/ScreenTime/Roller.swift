import DeviceActivity
import Foundation
import ManagedSettings
import ThymeCore

/// Rolling ladders (PLAN.md §4.1, §11). Each activity keeps only the next few thresholds per item, and the
/// extension re-registers an activity after each crossing in it. Each activity's items (with tokens) live in their
/// own small file, so the extension never loads the whole scan.
enum Roller {
    /// One registered activity: its items, or the total ladder when `items` is empty.
    struct Activity: Codable, Sendable {
        var name: String
        var day: DayKey
        var items: [TrackedItem]
        /// Highest total minute registered, for the total activity.
        var totalUpTo = 0

        var isTotal: Bool { items.isEmpty }
    }

    static let ladder = RollingLadder()

    /// Daily, so every count resets at midnight.
    static var schedule: DeviceActivitySchedule {
        DeviceActivitySchedule(intervalStart: DateComponents(hour: 0, minute: 0),
                               intervalEnd: DateComponents(hour: 23, minute: 59), repeats: true)
    }

    static var directory: URL { AppGroup.container.appending(path: "Rolling") }

    // MARK: - App

    /// Replaces all monitoring with `items` for `epochID`, starting each item after what's already known today, and
    /// journals a tracking start (iOS replays already-passed thresholds as a catch-up).
    static func registerAll(epochID: UUID, kid: Kid, items: [TrackedItem], now: Date = Date()) throws -> LadderEpoch {
        let center = DeviceActivityCenter()
        center.stopMonitoring()  // deliberately everything: a scan replaces all of this app's monitoring
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let day = DayKey(now)
        let state = MonitorStateStore.load(day: day)
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var activities = [Activity(name: RollingLadder.totalActivity(epochID: epochID), day: day, items: [])]
        for plan in RollingLadder.itemActivities(epochID: epochID, itemIDs: items.map(\.id)) {
            activities.append(Activity(name: plan.name, day: day, items: plan.itemIDs.compactMap { byID[$0] }))
        }
        try? AppGroup.journal.append(JournalEntry(kind: .trackingStart, activity: activities[0].name, at: now))
        for activity in activities {
            try register(activity, state: state, center: center)
        }
        recordRegistration(activities.map(\.name), center: center)
        return LadderEpoch(id: epochID, kidID: kid.id, startedAt: now, activityNames: activities.map(\.name),
                           itemIDs: items.map(\.id), spec: ladder.spec)
    }

    // MARK: - Extension

    /// After a crossing: re-register its activity with the next thresholds (for the total, only when running low).
    static func roll(activityName: String, fire: EventName.Parsed, state: MonitorDayState) {
        AppGroup.withLock("roll-\(activityName)") {
            guard var activity = load(activityName) else { return }
            if activity.isTotal, !ladder.totalNeedsRefill(crossed: fire.minute, registeredUpTo: activity.totalUpTo) {
                return
            }
            activity.day = state.day
            do {
                try register(activity, state: state, center: DeviceActivityCenter())
            } catch {
                try? AppGroup.journal.append(.note("roll failed for \(activityName): \(error.localizedDescription)"))
            }
        }
    }

    /// A new interval: at midnight, start the activity's ladders over. Our own re-registrations also start an
    /// interval; those find the activity already on today and do nothing.
    static func intervalStarted(activityName: String, now: Date = Date()) {
        AppGroup.withLock("roll-\(activityName)") {
            let today = DayKey(now)
            guard var activity = load(activityName), activity.day != today else { return }
            activity.day = today
            try? register(activity, state: MonitorDayState(day: today), center: DeviceActivityCenter())
        }
    }

    // MARK: - Registration

    static func register(_ activity: Activity, state: MonitorDayState, center: DeviceActivityCenter) throws {
        var activity = activity
        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        if activity.isTotal {
            let minutes = ladder.totalThresholds(after: state.totalMinute)
            for minute in minutes {
                events[.init(EventName.total(minute: minute))] = DeviceActivityEvent(
                    threshold: DateComponents(minute: minute), includesPastActivity: true)
            }
            activity.totalUpTo = minutes.last ?? state.totalMinute
        } else {
            for item in activity.items {
                let after = state.itemMinutes[item.id] ?? 0
                for minute in ladder.itemThresholds(after: after, short: item.kind == .domain) {
                    guard let event = event(for: item, minute: minute) else { continue }
                    events[.init(EventName.item(item.id, minute: minute))] = event
                }
            }
        }
        try center.startMonitoring(DeviceActivityName(activity.name), during: schedule, events: events)
        try save(activity)
    }

    static func event(for item: TrackedItem, minute: Int) -> DeviceActivityEvent? {
        let threshold = DateComponents(minute: minute)
        switch item.kind {
        case .app:
            guard let token = TokenCoding.application(item.tokenData) else { return nil }
            return DeviceActivityEvent(applications: [token], threshold: threshold, includesPastActivity: true)
        case .domain:
            guard let token = TokenCoding.webDomain(item.tokenData) else { return nil }
            return DeviceActivityEvent(webDomains: [token], threshold: threshold, includesPastActivity: true)
        case .category:
            guard let token = TokenCoding.category(item.tokenData) else { return nil }
            return DeviceActivityEvent(categories: [token], threshold: threshold, includesPastActivity: true)
        }
    }

    /// What we registered vs what DeviceActivityCenter reports back, as a journal note.
    static func recordRegistration(_ names: [String], center: DeviceActivityCenter) {
        let active = Set(center.activities.map(\.rawValue))
        let counts = names.map { name in
            active.contains(name) ? "\(center.events(for: DeviceActivityName(name)).count)" : "missing"
        }
        let text = "registered \(names.count) rolling, iOS reports \(active.count) active; events: " + counts.joined(separator: ",")
        try? AppGroup.journal.append(.note(text))
    }

    // MARK: - Files

    private static func url(_ name: String) -> URL {
        directory.appending(path: "\(name).json")
    }

    static func load(_ name: String) -> Activity? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? JSONDecoder.thyme.decode(Activity.self, from: data)
    }

    private static func save(_ activity: Activity) throws {
        try JSONEncoder.thyme.encode(activity).write(to: url(activity.name), options: .atomic)
    }
}
