import Foundation

/// One record of the family zone, as the CloudKit records debug screen counts it.
public struct RecordSummary: Sendable, Hashable {
    public var type: String
    /// Nil for the family's own records (the link key, bug tracker, places and the share).
    public var kidID: UUID?
    /// The record's field data: CloudKit's own metadata isn't included.
    public var bytes: Int
    public var createdAt: Date?

    public init(type: String, kidID: UUID?, bytes: Int, createdAt: Date?) {
        self.type = type
        self.kidID = kidID
        self.bytes = bytes
        self.createdAt = createdAt
    }
}

public struct RecordTally: Sendable, Hashable {
    public var count = 0
    public var bytes = 0

    public init(count: Int = 0, bytes: Int = 0) {
        self.count = count
        self.bytes = bytes
    }

    mutating func add(_ record: RecordSummary) {
        count += 1
        bytes += record.bytes
    }
}

/// How long ago a record was created, in calendar days.
public enum RecordAge: Int, CaseIterable, Sendable, Comparable {
    case today, lastWeek, lastMonth, lastQuarter, older, unknown

    public var title: String {
        switch self {
        case .today: "Today"
        case .lastWeek: "1–7 days ago"
        case .lastMonth: "8–30 days ago"
        case .lastQuarter: "31–90 days ago"
        case .older: "Over 90 days ago"
        case .unknown: "Unknown"
        }
    }

    public init(of date: Date?, now: Date, calendar: Calendar = .current) {
        guard let date else {
            self = .unknown
            return
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        self = switch days {
        case ...0: .today
        case 1...7: .lastWeek
        case 8...30: .lastMonth
        case 31...90: .lastQuarter
        default: .older
        }
    }

    public static func < (a: RecordAge, b: RecordAge) -> Bool { a.rawValue < b.rawValue }
}

/// Counts and sizes of the family zone's records by kid, record type and age.
public struct RecordStats: Sendable {
    public private(set) var total = RecordTally()
    public private(set) var byKid: [UUID?: RecordTally] = [:]
    public private(set) var byType: [String: RecordTally] = [:]
    public private(set) var byAge: [RecordAge: RecordTally] = [:]

    public init(_ records: [RecordSummary], now: Date = Date(), calendar: Calendar = .current) {
        for record in records {
            total.add(record)
            byKid[record.kidID, default: RecordTally()].add(record)
            byType[record.type, default: RecordTally()].add(record)
            byAge[RecordAge(of: record.createdAt, now: now, calendar: calendar), default: RecordTally()].add(record)
        }
    }

    /// Largest first, then by name.
    public var typesBySize: [(type: String, tally: RecordTally)] {
        byType.map { ($0.key, $0.value) }.sorted { ($1.tally.bytes, $0.type) < ($0.tally.bytes, $1.type) }
    }

    /// Youngest first; ages with no records are left out.
    public var ages: [(age: RecordAge, tally: RecordTally)] {
        byAge.map { ($0.key, $0.value) }.sorted { $0.age < $1.age }
    }
}
