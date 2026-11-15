import Foundation

/// What the monitor extension remembers between fires, for rule evaluation. Reset at each new day.
public struct MonitorDayState: Codable, Sendable, Equatable {
    public var day: DayKey
    public var totalMinute = 0
    public var lastTotalFireAt: Date?
    /// Start of the current run of use, from the total ladder.
    public var runStart: Date?
    /// Item crossings within the current run, to name the dominant app.
    public var runCrossings: [UUID: Int] = [:]
    /// Last crossing minute per item today.
    public var itemMinutes: [UUID: Int] = [:]
    /// One-shot alert keys already sent today.
    public var fired: Set<String> = []
    /// Last send time of repeating alerts.
    public var lastAlertAt: [String: Date] = [:]

    public init(day: DayKey) {
        self.day = day
    }

    /// Updates the state with a fire, starting over on a new day. The extension keeps this even without rules:
    /// rolling ladders register each item's next thresholds after `itemMinutes`.
    public mutating func record(_ fire: EventName.Parsed, at: Date, calendar: Calendar = .current) {
        let today = DayKey(at, calendar: calendar)
        if day != today {
            self = MonitorDayState(day: today)
        }
        if let itemID = fire.itemID {
            itemMinutes[itemID] = max(itemMinutes[itemID] ?? 0, fire.minute)
            if let last = lastTotalFireAt, at.timeIntervalSince(last) <= Reconstructor.runGap {
                runCrossings[itemID, default: 0] += 1
            }
        } else {
            guard fire.minute > totalMinute else { return }
            if lastTotalFireAt.map({ at.timeIntervalSince($0) > Reconstructor.runGap }) ?? true {
                runStart = at.addingTimeInterval(-60)
                runCrossings = [:]
            }
            lastTotalFireAt = at
            totalMinute = fire.minute
        }
    }
}

/// Evaluates kid-side rules on each fire (PLAN.md §4.6). Pure: the extension persists `MonitorDayState`.
public struct RuleEngine: Sendable {
    public var kidID: UUID
    public var kidName: String
    public var items: [UUID: TrackedItem]
    public var spec: LadderSpec
    public var calendar: Calendar

    public init(kidID: UUID, kidName: String, items: [UUID: TrackedItem], spec: LadderSpec = .standard,
                calendar: Calendar = .current) {
        self.kidID = kidID
        self.kidName = kidName
        self.items = items
        self.spec = spec
        self.calendar = calendar
    }

    public func process(_ fire: EventName.Parsed, at: Date, state: inout MonitorDayState, rules: [Rule]) -> [AlertRecord] {
        state.record(fire, at: at, calendar: calendar)

        var alerts: [AlertRecord] = []
        for rule in rules where rule.enabled && rule.kidID == kidID {
            alerts += evaluate(rule, fire: fire, at: at, state: &state)
        }
        return alerts
    }

    func evaluate(_ rule: Rule, fire: EventName.Parsed, at: Date, state: inout MonitorDayState) -> [AlertRecord] {
        switch rule.condition {
        case let .quietHours(windowName, start, end, weekdays, repeatEvery):
            guard let window = quietWindowStart(at: at, start: start, end: end, weekdays: weekdays) else { return [] }
            let key = "q.\(rule.id).\(Int(window.timeIntervalSince1970))"
            if let itemID = fire.itemID {
                let itemKey = key + ".\(itemID)"
                guard !state.fired.contains(itemKey) else { return [] }
                state.fired.insert(itemKey)
                return [alert(rule, item: itemID, at: at, title: "\(kidName): \(windowName)",
                              body: "\(name(of: itemID)) is open (\(fire.minute) min today).")]
            }
            if let last = state.lastAlertAt[key] {
                guard at.timeIntervalSince(last) >= Double(repeatEvery) * 60 else { return [] }
                state.lastAlertAt[key] = at
                return [alert(rule, item: nil, at: at, title: "\(kidName): still on the phone",
                              body: "Still in use during \(windowName) (\(clock(at))).")]
            }
            state.lastAlertAt[key] = at
            return [alert(rule, item: nil, at: at, title: "\(kidName): phone in use",
                          body: "In use during \(windowName) (\(clock(at))).")]

        case let .dailyThreshold(itemID, minutes):
            guard fire.itemID == itemID, fire.minute >= minutes else { return [] }
            let key = "d.\(rule.id)"
            guard !state.fired.contains(key) else { return [] }
            state.fired.insert(key)
            let what = itemID.map(name(of:)) ?? "the phone"
            return [alert(rule, item: itemID, at: at, title: "\(kidName): \(what) over \(minutes) min",
                          body: "\(fire.minute) min on \(what) today.")]

        case let .longSession(minutes):
            guard fire.itemID == nil, let runStart = state.runStart,
                  at.timeIntervalSince(runStart) >= Double(minutes) * 60 else { return [] }
            let key = "l.\(rule.id).\(Int(runStart.timeIntervalSince1970))"
            guard !state.fired.contains(key) else { return [] }
            state.fired.insert(key)
            let length = Int(at.timeIntervalSince(runStart) / 60)
            let dominant = state.runCrossings.max { $0.value < $1.value }?.key
            let mostly = dominant.map { ", mostly \(name(of: $0))" } ?? ""
            return [alert(rule, item: dominant, at: at, title: "\(kidName): long session",
                          body: "On the phone for \(length) min straight\(mostly).")]

        case let .unexplainedUsage(minutes):
            guard fire.itemID == nil else { return [] }
            let unexplained = state.totalMinute - explainedMinutes(state)
            guard unexplained >= minutes else { return [] }
            let key = "u.\(rule.id)"
            guard !state.fired.contains(key) else { return [] }
            state.fired.insert(key)
            return [alert(rule, item: nil, at: at, title: "\(kidName): untracked app use",
                          body: "\(unexplained)+ min today aren't explained by tracked apps. Re-scan on their phone if they installed something new.")]

        case .staleness:
            return []
        }
    }

    /// The most minutes tracked apps and sites can account for: last crossing plus the remainder below the next step.
    /// Categories overlap apps, so they're excluded.
    public func explainedMinutes(_ state: MonitorDayState) -> Int {
        state.itemMinutes.reduce(0) { sum, entry in
            guard let kind = items[entry.key]?.kind, kind != .category else { return sum }
            return sum + entry.value + spec.itemRemainder(after: entry.value, short: kind == .domain)
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
        guard let item = items[itemID] else { return "an app" }
        return item.nickname ?? item.fallbackName
    }

    func clock(_ date: Date) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return RuleCondition.clock(parts.hour! * 60 + parts.minute!)
    }

    func alert(_ rule: Rule, item: UUID?, at: Date, title: String, body: String) -> AlertRecord {
        AlertRecord(kidID: kidID, ruleID: rule.id, itemID: item, at: at, title: title, body: body)
    }
}
