import Foundation

/// A stretch of continuous use. `item == nil` is use that no app accounts for (counts toward the total only).
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

public struct SyntheticOptions: Sendable {
    /// Total fires inside each interval are held and delivered together at its end, like a system catch-up.
    public var catchUp: [DateInterval] = []
    /// Extra total fires, to mimic misfires.
    public var injected: [FirePoint] = []
    /// Minutes of use between wakes, as in `RollingLadder.step`.
    public var step = 2

    public init(catchUp: [DateInterval] = [], injected: [FirePoint] = [], step: Int = 2) {
        self.catchUp = catchUp
        self.injected = injected
        self.step = step
    }
}

/// Simulates capture for a list of (sequential) sessions: the total fires the extension would journal and the
/// samples it would compute from Apple's data at each wake.
public enum SyntheticTrace {
    public static let activity = "st.synthetic.tot"

    public static func generate(kid: UUID, sessions: [SyntheticSession], options: SyntheticOptions = SyntheticOptions(),
                                calendar: Calendar = .current) -> (entries: [JournalEntry], samples: [UsageSample]) {
        var total = 0
        var fires: [FirePoint] = []
        var samples: [UsageSample] = []
        // Per item: seconds since the last wake, and when that use began.
        var pending: [UUID: (seconds: Double, since: Date)] = [:]
        var lastWake: Date?
        for session in sessions.sorted(by: { $0.start < $1.start }) {
            for index in 0..<session.minutes {
                let minuteStart = session.start.addingTimeInterval(Double(index) * 60)
                let at = minuteStart.addingTimeInterval(60)
                total += 1
                if let item = session.item {
                    pending[item, default: (0, minuteStart)].seconds += 60
                }
                guard total % options.step == 0 else { continue }
                fires.append(FirePoint(minute: total, at: at))
                for (item, use) in pending {
                    // Like `Sampler`: Apple's numbers only say "since the previous fetch", within the hour.
                    let hour = calendar.dateInterval(of: .hour, for: use.since)?.start ?? use.since
                    samples.append(UsageSample(id: Replay.stableUUID("sample", kid.uuidString, item.uuidString, "\(at.timeIntervalSince1970)"),
                                               kidID: kid, itemID: item, day: DayKey(at, calendar: calendar),
                                               start: max(hour, lastWake ?? hour), end: at, seconds: use.seconds, reportedAt: at))
                }
                pending = [:]
                lastWake = at
            }
        }
        fires = fires.map { fire in
            guard let hold = options.catchUp.first(where: { $0.contains(fire.at) }) else { return fire }
            return FirePoint(minute: fire.minute, at: hold.end)
        }
        fires += options.injected
        let entries = fires
            .sorted { ($0.at, $0.minute) < ($1.at, $1.minute) }
            .map { JournalEntry(kind: .threshold, activity: activity, event: EventName.total(minute: $0.minute), at: $0.at) }
        return (entries, samples.sorted { $0.end < $1.end })
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

    /// Name, bundle ID and Apple's category.
    public static let apps = [
        ("YouTube", "com.google.ios.youtube", "Entertainment"), ("Roblox", "com.roblox.robloxmobile", "Games"),
        ("Messages", "com.apple.MobileSMS", "Social"), ("TikTok", "com.zhiliaoapp.musically", "Social"),
        ("Minecraft", "com.mojang.minecraftpe", "Games"), ("Safari", "com.apple.mobilesafari", "Information & Reading"),
        ("Classroom", "com.google.classroom", "Education"),
    ]

    public func trace(kid: Kid, day: DayKey, calendar: Calendar = .current) -> Trace {
        let start = day.start(in: calendar)
        let items = Self.apps.map { name, bundle, category in
            TrackedItem(kidID: kid.id, kind: .app, identifier: bundle, name: name, category: category, firstSeen: start)
        }
        let ids = Dictionary(uniqueKeysWithValues: items.map { ($0.name!, $0.id) })
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
            options.injected = [FirePoint(minute: 60, at: at(0, 1))]
        }
        let (entries, samples) = SyntheticTrace.generate(kid: kid.id, sessions: sessions, options: options,
                                                         calendar: calendar)
        let epoch = LadderEpoch(id: Replay.stableUUID("synthetic-epoch", kid.id.uuidString), kidID: kid.id,
                                startedAt: start, activityNames: [SyntheticTrace.activity])
        return Trace(kid: kid, day: day, items: items, epoch: epoch, entries: entries, samples: samples)
    }

    /// Where the phone stayed (PLAN.md §19), for the school day only: home, school, a stop on the way back, home again,
    /// with travel between. Spots in a public park, for screenshots. Each visit is reported on arrival and again with
    /// its departure, as iOS does.
    public func placeEvents(kid: Kid, day: DayKey, calendar: Calendar = .current) -> [PlaceEvent] {
        guard self == .schoolDay else { return [] }
        let start = day.start(in: calendar)
        func at(_ hour: Int, _ minute: Int) -> Date { start.addingTimeInterval(Double(hour * 3600 + minute * 60)) }
        let stays: [(name: String, lat: Double, lon: Double, accuracy: Double, from: Date, to: Date?)] = [
            ("home", 37.76955, -122.48310, 35, start.addingTimeInterval(-6 * 3600), at(7, 40)),
            ("school", 37.76990, -122.46610, 60, at(8, 0), at(15, 10)),
            ("stop", 37.76790, -122.45640, 120, at(15, 25), at(15, 55)),
            ("home", 37.76940, -122.48290, 25, at(16, 5), nil),
        ]
        return stays.enumerated().flatMap { index, stay -> [PlaceEvent] in
            func visit(_ part: String, departure: Date?, observed: Date) -> PlaceEvent {
                PlaceEvent(id: Replay.stableUUID("synthetic-visit", kid.id.uuidString, day.description, "\(index)", part),
                           kidID: kid.id, kind: .visit, at: stay.from, observedAt: observed, departure: departure,
                           latitude: stay.lat, longitude: stay.lon, accuracy: stay.accuracy)
            }
            let arrival = visit("arrival", departure: nil, observed: stay.from.addingTimeInterval(180))
            guard let to = stay.to else { return [arrival] }
            return [arrival, visit("departure", departure: to, observed: to.addingTimeInterval(80))]
        }
    }
}
