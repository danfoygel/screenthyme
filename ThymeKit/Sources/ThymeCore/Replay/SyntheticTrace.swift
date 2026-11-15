import Foundation

/// A stretch of continuous use. `item == nil` is an untracked app (counts toward the total only).
public struct SyntheticSession: Sendable, Hashable {
    public var item: UUID?
    public var start: Date
    public var minutes: Int

    public init(item: UUID?, start: Date, minutes: Int) {
        self.item = item
        self.start = start
        self.minutes = minutes
    }
}

/// A fire injected at an arbitrary time, to mimic iOS 26 misfires.
public struct SyntheticFire: Sendable, Hashable {
    public var item: UUID?
    public var minute: Int
    public var at: Date

    public init(item: UUID?, minute: Int, at: Date) {
        self.item = item
        self.minute = minute
        self.at = at
    }
}

public struct SyntheticOptions: Sendable {
    /// Fires inside each interval are held and delivered together at its end, like a system catch-up.
    public var catchUp: [DateInterval] = []
    public var injected: [SyntheticFire] = []
    /// Item fires arrive this long after the total fire for the same minute.
    public var itemFireDelay: TimeInterval = 0.5

    public init(catchUp: [DateInterval] = [], injected: [SyntheticFire] = [], itemFireDelay: TimeInterval = 0.5) {
        self.catchUp = catchUp
        self.injected = injected
        self.itemFireDelay = itemFireDelay
    }
}

/// Simulates the ladders for a list of (sequential) sessions: what the monitor extension would have journaled.
public enum SyntheticTrace {
    public static let activity = "st.synthetic.0"

    public static func entries(sessions: [SyntheticSession], spec: LadderSpec = .standard,
                               options: SyntheticOptions = SyntheticOptions()) -> [JournalEntry] {
        let totalSteps = Set(spec.totalMinutes)
        let itemSteps = Set(spec.itemMinutes)
        var total = 0
        var perItem: [UUID: Int] = [:]
        var fires: [SyntheticFire] = []
        for session in sessions.sorted(by: { $0.start < $1.start }) {
            for index in 0..<session.minutes {
                let at = session.start.addingTimeInterval(Double(index + 1) * 60)
                total += 1
                if totalSteps.contains(total) {
                    fires.append(SyntheticFire(item: nil, minute: total, at: at))
                }
                if let item = session.item {
                    perItem[item, default: 0] += 1
                    if itemSteps.contains(perItem[item]!) {
                        fires.append(SyntheticFire(item: item, minute: perItem[item]!,
                                                   at: at.addingTimeInterval(options.itemFireDelay)))
                    }
                }
            }
        }
        fires = fires.map { fire in
            guard let hold = options.catchUp.first(where: { $0.contains(fire.at) }) else { return fire }
            var held = fire
            held.at = hold.end
            return held
        }
        fires += options.injected
        return fires
            .sorted { ($0.at, $0.minute) < ($1.at, $1.minute) }
            .map { fire in
                let name = fire.item.map { EventName.item($0, minute: fire.minute) } ?? EventName.total(minute: fire.minute)
                return JournalEntry(kind: .threshold, activity: activity, event: name, at: fire.at)
            }
    }
}

/// Ready-made days for the replay tool and tests.
public enum SyntheticScenario: String, CaseIterable, Codable, Sendable, Identifiable {
    case schoolDay, fastSwitching, bedtime, catchUpBurst

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .schoolDay: "School day"
        case .fastSwitching: "Fast app switching"
        case .bedtime: "Bedtime violation"
        case .catchUpBurst: "Catch-up burst"
        }
    }

    public static let appNames = ["YouTube", "Roblox", "Messages", "TikTok", "Minecraft", "Safari", "Classroom"]

    public func trace(kid: Kid, day: DayKey, calendar: Calendar = .current) -> Trace {
        let epochID = Replay.stableUUID("synthetic-epoch", kid.id.uuidString)
        let items = Self.appNames.enumerated().map { index, name in
            TrackedItem(id: Replay.stableUUID("synthetic", kid.id.uuidString, name), kidID: kid.id, kind: .app,
                        tokenData: nil, nickname: name, ordinal: index + 1, firstSeenEpoch: epochID)
        }
        let ids = Dictionary(uniqueKeysWithValues: zip(Self.appNames, items.map(\.id)))
        let start = day.start(in: calendar)
        func at(_ hour: Int, _ minute: Int) -> Date {
            start.addingTimeInterval(Double(hour * 3600 + minute * 60))
        }

        var options = SyntheticOptions()
        var sessions: [SyntheticSession]
        switch self {
        case .schoolDay:
            sessions = [
                SyntheticSession(item: ids["Messages"], start: at(7, 10), minutes: 8),
                SyntheticSession(item: ids["Classroom"], start: at(15, 30), minutes: 25),
                SyntheticSession(item: ids["YouTube"], start: at(16, 0), minutes: 47),
                SyntheticSession(item: nil, start: at(16, 50), minutes: 3),
                SyntheticSession(item: ids["Roblox"], start: at(17, 0), minutes: 65),
                SyntheticSession(item: ids["TikTok"], start: at(20, 15), minutes: 32),
            ]
        case .fastSwitching:
            sessions = []
            var cursor = at(18, 0)
            for index in 0..<30 {
                let name = ["YouTube", "Messages", "TikTok"][index % 3]
                let length = [2, 1, 3][index % 3]
                sessions.append(SyntheticSession(item: ids[name], start: cursor, minutes: length))
                cursor = cursor.addingTimeInterval(Double(length) * 60)
            }
        case .bedtime:
            sessions = [
                SyntheticSession(item: ids["YouTube"], start: at(19, 0), minutes: 40),
                SyntheticSession(item: ids["TikTok"], start: at(22, 35), minutes: 50),
                SyntheticSession(item: ids["Minecraft"], start: at(23, 30), minutes: 20),
            ]
        case .catchUpBurst:
            sessions = [
                SyntheticSession(item: ids["Minecraft"], start: at(14, 0), minutes: 90),
                SyntheticSession(item: ids["Safari"], start: at(16, 0), minutes: 20),
            ]
            options.catchUp = [DateInterval(start: at(14, 20), end: at(15, 0))]
            options.injected = [SyntheticFire(item: ids["YouTube"], minute: 60, at: at(0, 1))]
        }
        let entries = SyntheticTrace.entries(sessions: sessions, options: options)
        let epoch = LadderEpoch(id: epochID, kidID: kid.id, startedAt: start, activityNames: [SyntheticTrace.activity],
                                itemIDs: items.map(\.id), spec: .standard)
        return Trace(kid: kid, day: day, items: items, epoch: epoch, entries: entries)
    }
}
