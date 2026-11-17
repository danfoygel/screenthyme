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
        /// Highest threshold registered, in iOS's minutes.
        var upTo = 0
        /// Since the last fresh registration; nil after midnight, when both counts start over (PLAN.md §16).
        var calibration: LadderCalibration?

        /// Our minutes minus iOS's.
        var offset: Int { calibration?.offset ?? 0 }
    }

    /// What a wake-alarm fire was.
    enum Fire: Equatable {
        /// Use, at this minute of ours.
        case use(minute: Int)
        /// A probe or a replay: it only tells where iOS's count is.
        case calibration
        /// Not the wake alarm's (old per-app ladders).
        case unknown
    }

    /// Probes replay in random order: wait this long for the rest before the highest settles the offset.
    static let probeSettleDelay: TimeInterval = 3

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
        // Every activity but the Enforcer's and the token matcher's. Never an empty list: that stops everything.
        let old = center.activities.filter {
            !Enforcer.owns($0.rawValue) && $0.rawValue != TokenMatcher.activity.rawValue
        }
        // The old state stays until the new registration replaces it: a registration that throws must not leave the
        // alarm running with no state, which stops every roll and the midnight restart.
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let day = DayKey(now)
        let total = MonitorStateStore.load(day: day).totalMinute
        let activity = Activity(name: RollingLadder.activityName(epochID: epochID), day: day,
                                calibration: LadderCalibration(base: total, registeredAt: now))
        try? AppGroup.journal.append(JournalEntry(kind: .trackingStart, activity: activity.name, at: now))
        // Under the lock, the extension's callbacks for this registration (its interval start, the replays) wait for
        // the new state. Without it, an old or missing state made the interval start re-register from 0 over ours,
        // dropping the probes.
        try AppGroup.withLock("roll") {
            if !old.isEmpty { center.stopMonitoring(old) }
            // Probes find out whether iOS restarted today's count lower, as a new authorization grant can.
            try register(activity, after: total, probes: ladder.probes(below: total), center: center)
        }
        let active = center.activities.map(\.rawValue)
        let events = center.events(for: DeviceActivityName(activity.name)).count
        try? AppGroup.journal.append(.note("registered \(activity.name): \(events) events, iOS reports \(active.count) active"))
        // A new authorization grant stopped the Enforcer's and the token matcher's activities too.
        Enforcer.reconcile(now: now)
        TokenMatcher.ensureRegistered()
        return LadderEpoch(id: epochID, kidID: kid.id, startedAt: now, activityNames: [activity.name])
    }

    // MARK: - Extension

    /// A fire of the wake alarm, in iOS's minutes, as ours. Probes and replays only calibrate (PLAN.md §16).
    static func observe(_ eventName: String, at date: Date) -> Fire {
        if let probe = EventName.parseProbe(eventName) {
            return probePassed(probe, at: date)
        }
        guard let parsed = EventName.parse(eventName), parsed.itemID == nil else { return .unknown }
        return AppGroup.withLock("roll") {
            // A new day's counts start over together, even before `intervalStarted` clears the calibration.
            guard var activity = load(), activity.day == DayKey(date), var calibration = activity.calibration else {
                return .use(minute: parsed.minute)
            }
            if let minute = calibration.ladderFired(parsed.minute, at: date) { return .use(minute: minute) }
            activity.calibration = calibration
            save(activity)
            // Replays can use up the ladder too.
            if ladder.needsRefill(crossed: parsed.minute, registeredUpTo: activity.upTo) {
                reregister(activity, after: parsed.minute)
            }
            return .calibration
        }
    }

    private static func probePassed(_ minute: Int, at date: Date) -> Fire {
        let recorded = AppGroup.withLock("roll") { () -> Bool in
            guard var activity = load(), activity.day == DayKey(date), var calibration = activity.calibration,
                  calibration.probePassed(minute, at: date) else { return false }
            activity.calibration = calibration
            save(activity)
            return true
        }
        guard recorded else { return .calibration }
        Thread.sleep(forTimeInterval: probeSettleDelay)
        AppGroup.withLock("roll") {
            // Only the highest probe settles; the others return.
            guard var activity = load(), var calibration = activity.calibration, calibration.floor == minute,
                  let after = calibration.settle(at: Date(), step: ladder.step) else { return }
            activity.calibration = calibration
            try? AppGroup.journal.append(.note("wake alarm: iOS counts \(calibration.offset) min less than our \(calibration.base)"))
            reregister(activity, after: after)
        }
        return .calibration
    }

    /// After a fire of use (in our minutes): re-register with the next thresholds when running low.
    static func roll(after minute: Int, state: MonitorDayState) {
        AppGroup.withLock("roll") {
            guard var activity = load() ?? recovered() else { return }
            if activity.day != state.day { activity.calibration = nil }
            guard ladder.needsRefill(crossed: minute - activity.offset, registeredUpTo: activity.upTo) else { return }
            activity.day = state.day
            reregister(activity, after: max(minute, state.totalMinute) - activity.offset)
        }
    }

    /// Call under the "roll" lock. `minute` is iOS's.
    private static func reregister(_ activity: Activity, after minute: Int) {
        do {
            try register(activity, after: minute, center: DeviceActivityCenter())
        } catch {
            try? AppGroup.journal.append(.note("roll failed: \(error.localizedDescription)"))
        }
    }

    /// At the first callback of a new day, start over: the alarm's own midnight interval start, or any other callback
    /// if that one was missed or its registration failed. Until then the alarm sits at yesterday's thresholds, which
    /// today's count won't reach for hours of use. Our own re-registrations also start an interval; those find the
    /// activity already on today and do nothing.
    static func startDayIfNeeded(now: Date = Date()) {
        AppGroup.withLock("roll") {
            let today = DayKey(now)
            // Only the current epoch's alarm: after monitoring was stopped, the Enforcer's intervals must not bring
            // back a leftover state's.
            guard var activity = load() ?? recovered(), activity.day != today,
                  SharedConfig.load().epoch?.activityNames.contains(activity.name) == true else { return }
            activity.day = today
            activity.calibration = nil
            do {
                try register(activity, after: 0, center: DeviceActivityCenter())
                try? AppGroup.journal.append(.note("wake alarm: new day"))
            } catch {
                try? AppGroup.journal.append(.note("wake alarm: new day failed: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: - Registration

    /// Ladder events after `minute` and `probes`, all in iOS's minutes.
    private static func register(_ activity: Activity, after minute: Int, probes: [Int] = [],
                                 center: DeviceActivityCenter) throws {
        var activity = activity
        let minutes = ladder.thresholds(after: minute)
        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        for minute in minutes {
            events[.init(EventName.total(minute: minute))] = DeviceActivityEvent(
                threshold: DateComponents(minute: minute), includesPastActivity: true)
        }
        for probe in probes {
            events[.init(EventName.probe(minute: probe))] = DeviceActivityEvent(
                threshold: DateComponents(minute: probe), includesPastActivity: true)
        }
        try center.startMonitoring(DeviceActivityName(activity.name), during: schedule, events: events)
        activity.upTo = minutes.last ?? minute
        try JSONEncoder.thyme.encode(activity).write(to: url, options: .atomic)
    }

    private static func save(_ activity: Activity) {
        try? JSONEncoder.thyme.encode(activity).write(to: url, options: .atomic)
    }

    /// The registered alarm when its state file is gone: as if registered on no day, so the next roll or interval
    /// start registers it afresh.
    private static func recovered() -> Activity? {
        guard let name = SharedConfig.load().epoch?.activityNames.first else { return nil }
        try? AppGroup.journal.append(.note("wake alarm: state missing, re-registering \(name)"))
        return Activity(name: name, day: DayKey(Date.distantPast))
    }

    static func load() -> Activity? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.thyme.decode(Activity.self, from: data)
    }
}
