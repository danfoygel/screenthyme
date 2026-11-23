import Foundation

/// One family-zone record as CloudKit sent it: its name, type and JSON payload, or a deletion (no type).
public struct RawRecord: Codable, Sendable, Hashable {
    public var name: String
    /// Nil for a deletion.
    public var type: String?
    public var payload: Data?

    public init(name: String, type: String, payload: Data) {
        self.name = name
        self.type = type
        self.payload = payload
    }

    private init(deleting name: String) {
        self.name = name
    }

    public static func deletion(_ name: String) -> RawRecord {
        RawRecord(deleting: name)
    }

    public var isDeletion: Bool { type == nil }
}

/// Every family-zone record a phone has fetched, kept as it came (PLAN.md §4.4): when a new build changes the mirror's
/// stored types, it decodes these again on the phone instead of fetching the whole zone. An append-only file, rewritten
/// without the overwritten lines when it has grown to twice what it holds.
///
/// It's whole only from a full fetch on: `startFullFetch` before one, `markComplete` after, and `covers(token:)` only
/// while the fetches since were all kept, which the change token they ended at shows (a build without this log fetches
/// without keeping them).
public struct RawRecordLog: Sendable {
    public struct State: Codable, Sendable, Equatable {
        /// Emptied for a full fetch from scratch, which `markComplete` then ends.
        public var fullFetch = false
        /// Holds the whole zone: that full fetch ended.
        public var complete = false
        /// The change token (archived) the last kept fetch ended at.
        public var token: Data?
        /// Lines in the file, and records it held at the last rewrite.
        public var lines = 0
        public var live = 0
    }

    public let directory: URL
    private var file: JSONLinesFile<RawRecord> { JSONLinesFile(url: directory.appending(path: "records.jsonl")) }
    private var stateURL: URL { directory.appending(path: "state.json") }

    public init(directory: URL) {
        self.directory = directory
    }

    public var state: State {
        (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder.thyme.decode(State.self, from: $0) } ?? State()
    }

    /// Whether the log holds the whole zone as of the fetch that ended at `token`.
    public func covers(token: Data?) -> Bool {
        let state = state
        return state.complete && token != nil && state.token == token
    }

    /// Empties the log for a full fetch from scratch.
    public func startFullFetch() {
        try? FileManager.default.removeItem(at: directory)
        save(State(fullFetch: true))
    }

    public func append(_ records: [RawRecord]) {
        guard !records.isEmpty else { return }
        var state = state
        do {
            try file.append(contentsOf: records)
        } catch {
            // A record missing from the log would be missing from a rebuild: fetch from scratch next time instead.
            state.complete = false
        }
        state.lines += records.count
        save(state)
        if state.lines > max(2 * state.live, state.live + 5000) { compact() }
    }

    /// A full fetch ended. One that began before the log was emptied for it (a build without the log started it) left
    /// it partial.
    public func markComplete() {
        var state = state
        guard state.fullFetch, !state.complete else { return }
        state.complete = true
        save(state)
    }

    /// The token the fetch just kept ended at.
    public func fetched(token: Data?) {
        var state = state
        guard state.token != token else { return }
        state.token = token
        save(state)
    }

    /// The records it holds, the last version of each, without deleted ones, in the order last written.
    public func records() -> [RawRecord] {
        var latest: [String: (order: Int, record: RawRecord)] = [:]
        for (order, record) in file.readAll().enumerated() {
            latest[record.name] = (order, record)
        }
        return latest.values.filter { !$0.record.isDeletion }.sorted { $0.order < $1.order }.map(\.record)
    }

    /// Rewrites the file with only what it holds.
    public func compact() {
        let records = records()
        let encoder = JSONEncoder.thyme
        var data = Data()
        for record in records {
            guard let line = try? encoder.encode(record) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        var state = state
        do {
            try data.write(to: file.url, options: .atomic)
            state.lines = records.count
            state.live = records.count
        } catch {
            state.complete = false
        }
        save(state)
    }

    private func save(_ state: State) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder.thyme.encode(state).write(to: stateURL, options: .atomic)
    }
}
