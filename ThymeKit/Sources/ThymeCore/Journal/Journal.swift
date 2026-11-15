import Foundation

/// What the monitor extension saw, written before anything else happens (PLAN.md §4.1).
public struct JournalEntry: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case threshold, intervalStart, intervalEnd
        /// Diagnostics from the app (registrations, missing schedules); `event` holds the text.
        case note
        /// The app (re)registered monitoring: iOS will replay today's already-passed thresholds as a catch-up.
        case trackingStart
    }

    public var id: UUID
    public var kind: Kind
    public var activity: String
    /// The DeviceActivityEvent name, for thresholds.
    public var event: String?
    public var at: Date

    public init(id: UUID = UUID(), kind: Kind, activity: String, event: String? = nil, at: Date) {
        self.id = id
        self.kind = kind
        self.activity = activity
        self.event = event
        self.at = at
    }

    public var parsedEvent: EventName.Parsed? {
        kind == .threshold ? event.flatMap(EventName.parse) : nil
    }

    public static func note(_ text: String, at: Date = Date()) -> JournalEntry {
        JournalEntry(kind: .note, activity: "app", event: text, at: at)
    }
}

/// One JSONL file per day plus a ledger of uploaded entry ids. Uploads are idempotent (record name = entry id),
/// so the app and the extension may both upload the same entry without harm.
public struct Journal: Sendable {
    public let directory: URL
    public let calendar: Calendar

    public init(directory: URL, calendar: Calendar = .current) {
        self.directory = directory
        self.calendar = calendar
    }

    public func append(_ entry: JournalEntry) throws {
        try file(for: DayKey(entry.at, calendar: calendar)).append(entry)
    }

    public func entries(on day: DayKey) -> [JournalEntry] {
        file(for: day).readAll().sorted { $0.at < $1.at }
    }

    public func days() -> [DayKey] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name in
            guard name.hasPrefix("journal-"), name.hasSuffix(".jsonl") else { return nil }
            return DayKey(string: String(name.dropFirst(8).dropLast(6)))
        }.sorted()
    }

    public func markUploaded(_ ids: [UUID], on day: DayKey) throws {
        try ledger(for: day).append(contentsOf: ids)
    }

    /// Entries not yet confirmed uploaded, oldest first, across the last `days` days.
    public func pending(days: Int = 7, now: Date = Date()) -> [JournalEntry] {
        let today = DayKey(now, calendar: calendar)
        let recent = days == 0 ? [] : (0..<days).map { today.adding(days: -$0, calendar: calendar) }
        return recent.reversed().flatMap { day -> [JournalEntry] in
            let uploaded = Set(ledger(for: day).readAll())
            return entries(on: day).filter { !uploaded.contains($0.id) }
        }
    }

    public func lastThresholdAt() -> Date? {
        for day in days().reversed() {
            if let last = entries(on: day).last(where: { $0.kind == .threshold }) {
                return last.at
            }
        }
        return nil
    }

    private func file(for day: DayKey) -> JSONLinesFile<JournalEntry> {
        JSONLinesFile(url: directory.appending(path: "journal-\(day).jsonl"))
    }

    private func ledger(for day: DayKey) -> JSONLinesFile<UUID> {
        JSONLinesFile(url: directory.appending(path: "uploaded-\(day).jsonl"))
    }
}
