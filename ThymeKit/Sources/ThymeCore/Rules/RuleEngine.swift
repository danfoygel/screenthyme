import Foundation

/// What the monitor extension saw at one wake: the total fire that woke it (if any) and Apple's per-app numbers.
public struct WakeObservation: Sendable {
    public var at: Date
    /// Today's total-use minutes, when a total threshold woke the extension.
    public var totalMinute: Int?
    /// Apple's cumulative seconds today, per item.
    public var itemSeconds: [UUID: Double]
    /// Seconds per item since the previous fetch.
    public var intervalSeconds: [UUID: Double]
    /// Items seen for the first time on this phone.
    public var newItems: [UUID]

    public init(at: Date, totalMinute: Int?, itemSeconds: [UUID: Double] = [:], intervalSeconds: [UUID: Double] = [:],
                newItems: [UUID] = []) {
        self.at = at
        self.totalMinute = totalMinute
        self.itemSeconds = itemSeconds
        self.intervalSeconds = intervalSeconds
        self.newItems = newItems
    }
}

/// What the monitor extension remembers between wakes, for the rolling ladder and rules. Reset at each new day.
public struct MonitorDayState: Codable, Sendable, Equatable {
    public var day: DayKey
    public var totalMinute = 0
    public var lastTotalFireAt: Date?
    /// Start of the current run of use, from total fires.
    public var runStart: Date?
    /// Seconds per item within the current run, to name the dominant app.
    public var runSeconds: [UUID: Double] = [:]
    /// Apple's cumulative seconds today, per item.
    public var itemSeconds: [UUID: Double] = [:]
    /// One-shot alert keys already sent today.
    public var fired: Set<String> = []
    /// Last send time of repeating alerts.
    public var lastAlertAt: [String: Date] = [:]

    public init(day: DayKey) {
        self.day = day
    }

    /// Updates the state with a wake, starting over on a new day.
    public mutating func record(_ wake: WakeObservation, calendar: Calendar = .current) {
        let today = DayKey(wake.at, calendar: calendar)
        if day != today {
            self = MonitorDayState(day: today)
        }
        if let minute = wake.totalMinute, minute > totalMinute {
            if lastTotalFireAt.map({ wake.at.timeIntervalSince($0) > Reconstructor.runGap + 60 }) ?? true {
                runStart = wake.at.addingTimeInterval(-60)
                runSeconds = [:]
            }
            lastTotalFireAt = wake.at
            totalMinute = minute
        }
        for (item, seconds) in wake.itemSeconds {
            itemSeconds[item] = max(itemSeconds[item] ?? 0, seconds)
        }
        for (item, seconds) in wake.intervalSeconds {
            runSeconds[item, default: 0] += seconds
        }
    }
}

/// Evaluates kid-side rules at each wake (PLAN.md §4.6). Pure: the extension persists `MonitorDayState`.
public struct RuleEngine: Sendable {
    public var kidID: UUID
    public var kidName: String
    public var items: [UUID: TrackedItem]
    public var calendar: Calendar

    public init(kidID: UUID, kidName: String, items: [UUID: TrackedItem], calendar: Calendar = .current) {
        self.kidID = kidID
        self.kidName = kidName
        self.items = items
        self.calendar = calendar
    }

    public func process(_ wake: WakeObservation, state: inout MonitorDayState, rules: [Rule]) -> [AlertRecord] {
        state.record(wake, calendar: calendar)
        var alerts: [AlertRecord] = []
        for rule in rules where rule.enabled && rule.kidID == kidID {
            alerts += evaluate(rule, wake: wake, state: &state)
        }
        return alerts
    }

    func evaluate(_ rule: Rule, wake: WakeObservation, state: inout MonitorDayState) -> [AlertRecord] {
        let at = wake.at
        switch rule.condition {
        case let .quietHours(windowName, start, end, weekdays, repeatEvery):
            guard let window = quietWindowStart(at: at, start: start, end: end, weekdays: weekdays) else { return [] }
            let key = "q.\(rule.id).\(Int(window.timeIntervalSince1970))"
            var alerts: [AlertRecord] = []
            for (item, seconds) in wake.intervalSeconds.sorted(by: { $0.value > $1.value }) where seconds >= 30 {
                let itemKey = key + ".\(item)"
                guard !state.fired.contains(itemKey) else { continue }
                state.fired.insert(itemKey)
                alerts.append(alert(rule, item: item, at: at, title: "\(kidName): \(windowName)",
                                    body: "\(name(of: item)) is open (\(minutes(state.itemSeconds[item])) min today)."))
            }
            guard wake.totalMinute != nil else { return alerts }
            if let last = state.lastAlertAt[key] {
                guard at.timeIntervalSince(last) >= Double(repeatEvery) * 60 else { return alerts }
                state.lastAlertAt[key] = at
                return alerts + [alert(rule, item: nil, at: at, title: "\(kidName): still on the phone",
                                       body: "Still in use during \(windowName) (\(clock(at))).")]
            }
            state.lastAlertAt[key] = at
            return [alert(rule, item: nil, at: at, title: "\(kidName): phone in use",
                          body: "In use during \(windowName) (\(clock(at))).")] + alerts

        case let .dailyThreshold(itemID, limit):
            let used = itemID.map { minutes(state.itemSeconds[$0]) } ?? state.totalMinute
            guard used >= limit else { return [] }
            let key = "d.\(rule.id)"
            guard !state.fired.contains(key) else { return [] }
            state.fired.insert(key)
            let what = itemID.map(name(of:))
            return [alert(rule, item: itemID, at: at, title: "\(kidName): \(what ?? "phone") over \(limit) min",
                          body: "\(used) min on \(what ?? "the phone") today.")]

        case let .longSession(limit):
            guard wake.totalMinute != nil, let runStart = state.runStart,
                  at.timeIntervalSince(runStart) >= Double(limit) * 60 else { return [] }
            let key = "l.\(rule.id).\(Int(runStart.timeIntervalSince1970))"
            guard !state.fired.contains(key) else { return [] }
            state.fired.insert(key)
            let length = Int(at.timeIntervalSince(runStart) / 60)
            let dominant = state.runSeconds.max { $0.value < $1.value }?.key
            let mostly = dominant.map { ", mostly \(name(of: $0))" } ?? ""
            return [alert(rule, item: dominant, at: at, title: "\(kidName): long session",
                          body: "On the phone for \(length) min straight\(mostly).")]

        case .newApp:
            return wake.newItems.map { item in
                alert(rule, item: item, at: at, title: "\(kidName): new app",
                      body: "First time using \(name(of: item)).")
            }

        case .staleness:
            return []
        }
    }

    /// The start of the quiet window containing `at`, or nil if `at` is outside every window.
    func quietWindowStart(at: Date, start: Int, end: Int, weekdays: Set<Int>) -> Date? {
        let parts = calendar.dateComponents([.hour, .minute], from: at)
        let minuteOfDay = parts.hour! * 60 + parts.minute!
        let today = calendar.startOfDay(for: at)
        let windowDay: Date
        if start <= end {
            guard minuteOfDay >= start, minuteOfDay < end else { return nil }
            windowDay = today
        } else if minuteOfDay >= start {
            windowDay = today
        } else if minuteOfDay < end {
            windowDay = calendar.date(byAdding: .day, value: -1, to: today)!
        } else {
            return nil
        }
        guard weekdays.isEmpty || weekdays.contains(calendar.component(.weekday, from: windowDay)) else { return nil }
        return calendar.date(byAdding: .minute, value: start, to: windowDay)
    }

    func name(of itemID: UUID) -> String {
        items[itemID]?.displayName ?? "an app"
    }

    func minutes(_ seconds: Double?) -> Int {
        Int(((seconds ?? 0) / 60).rounded(.down))
    }

    func clock(_ date: Date) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return RuleCondition.clock(parts.hour! * 60 + parts.minute!)
    }

    func alert(_ rule: Rule, item: UUID?, at: Date, title: String, body: String) -> AlertRecord {
        AlertRecord(kidID: kidID, ruleID: rule.id, itemID: item, at: at, title: title, body: body)
    }
}
