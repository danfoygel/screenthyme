import Foundation

/// One process's cumulative counters as the kernel reports them: zero at launch, only growing.
public struct EnergyCounters: Codable, Sendable, Hashable {
    public var energyNanojoules: UInt64
    public var cpuNanoseconds: UInt64
    public var wakeups: UInt64

    public init(energyNanojoules: UInt64, cpuNanoseconds: UInt64, wakeups: UInt64) {
        self.energyNanojoules = energyNanojoules
        self.cpuNanoseconds = cpuNanoseconds
        self.wakeups = wakeups
    }

    public static let zero = EnergyCounters(energyNanojoules: 0, cpuNanoseconds: 0, wakeups: 0)

    /// Growth since `earlier`, clamped at zero.
    func since(_ earlier: EnergyCounters) -> EnergyCounters {
        EnergyCounters(energyNanojoules: energyNanojoules.subtractingClamped(earlier.energyNanojoules),
                       cpuNanoseconds: cpuNanoseconds.subtractingClamped(earlier.cpuNanoseconds),
                       wakeups: wakeups.subtractingClamped(earlier.wakeups))
    }
}

public enum EnergySource: String, Codable, CodingKeyRepresentable, Sendable, CaseIterable {
    /// The DeviceActivityMonitor extension: every threshold fire, re-registration and upload.
    case monitor
    /// The host app: launches, background refreshes, pings, and the kid looking at it.
    case app
}

/// Daily energy accounting on the kid's phone, shared by the app and the extension (one JSON file under a lock).
/// Each sample is a process's cumulative counters; the growth since that process's previous sample goes to the
/// sample's day. A process's first sample counts in full, so its launch cost is included. Whatever a process uses
/// after its last sample (it's suspended or killed) is missed, so totals run slightly low.
public struct EnergyLedger: Codable, Sendable {
    struct ProcessMark: Codable, Sendable {
        var counters: EnergyCounters
        var at: Date
    }

    struct Day: Codable, Sendable {
        var usage: [EnergySource: EnergyUsage] = [:]
        var updatedAt: Date
        var uploadedAt: Date?
    }

    var processes: [UUID: ProcessMark] = [:]
    /// Keyed by `DayKey.description`.
    var days: [String: Day] = [:]

    public static let keepDays = 14

    public init() {}

    /// `isCallback` counts the sample as one wake-up of ours (an extension callback); app samples pass false.
    public mutating func record(_ counters: EnergyCounters, process: UUID, source: EnergySource, at date: Date,
                                isCallback: Bool, calendar: Calendar = .current) {
        let previous = processes[process]
        let delta = counters.since(previous?.counters ?? .zero)
        processes[process] = ProcessMark(counters: counters, at: date)

        let key = DayKey(date, calendar: calendar).description
        var day = days[key] ?? Day(updatedAt: date)
        var usage = day.usage[source] ?? EnergyUsage()
        usage.add(delta)
        if previous == nil { usage.launches += 1 }
        if isCallback { usage.callbacks += 1 }
        day.usage[source] = usage
        day.updatedAt = date
        days[key] = day
        prune(now: date, calendar: calendar)
    }

    public func usage(on day: DayKey, source: EnergySource) -> EnergyUsage {
        days[day.description]?.usage[source] ?? EnergyUsage()
    }

    /// Days with changes parents haven't seen: past days at once (their final numbers), today at most every
    /// `interval`, because each upload is itself work on the kid's phone.
    public func daysToUpload(now: Date, interval: TimeInterval = 15 * 60, calendar: Calendar = .current) -> [DayKey] {
        let today = DayKey(now, calendar: calendar)
        return days.compactMap { key, day -> DayKey? in
            guard let dayKey = DayKey(string: key), day.updatedAt > (day.uploadedAt ?? .distantPast) else { return nil }
            if dayKey < today { return dayKey }
            return now.timeIntervalSince(day.uploadedAt ?? .distantPast) >= interval ? dayKey : nil
        }
        .sorted()
    }

    public mutating func markUploaded(_ uploaded: [DayKey], at date: Date) {
        for day in uploaded { days[day.description]?.uploadedAt = date }
    }

    /// Processes unseen for two days are gone; their next sample would come from a new process anyway.
    private mutating func prune(now: Date, calendar: Calendar) {
        processes = processes.filter { now.timeIntervalSince($0.value.at) < 2 * 86_400 }
        let oldest = DayKey(now, calendar: calendar).adding(days: -Self.keepDays, calendar: calendar)
        days = days.filter { DayKey(string: $0.key).map { $0 > oldest } ?? false }
    }
}

extension UInt64 {
    fileprivate func subtractingClamped(_ other: UInt64) -> UInt64 {
        self > other ? self - other : 0
    }
}
