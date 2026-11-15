import CryptoKit
import Foundation

/// One recorded (or synthesized) day of a kid's capture: the replay tool's unit (PLAN.md §7.2).
public struct Trace: Codable, Sendable {
    public var version = 2
    public var kid: Kid
    public var day: DayKey
    public var items: [TrackedItem]
    public var epoch: LadderEpoch?
    /// Journal entries: total fires and tracking starts.
    public var entries: [JournalEntry]
    public var samples: [UsageSample]

    public init(kid: Kid, day: DayKey, items: [TrackedItem], epoch: LadderEpoch?, entries: [JournalEntry],
                samples: [UsageSample]) {
        self.kid = kid
        self.day = day
        self.items = items
        self.epoch = epoch
        self.entries = entries
        self.samples = samples
    }

    public func encoded() throws -> Data {
        try JSONEncoder.thyme.encode(self)
    }

    public static func decode(_ data: Data) throws -> Trace {
        try JSONDecoder.thyme.decode(Trace.self, from: data)
    }

    /// The trace's total fires and tracking starts as synced records (a tracking start is a fire at minute 0).
    public func fires(calendar: Calendar = .current) -> [UsageFire] {
        entries.compactMap { entry in
            let minute: Int
            if entry.isTrackingStart {
                minute = 0
            } else if let parsed = entry.parsedEvent, parsed.itemID == nil {
                minute = parsed.minute
            } else {
                return nil
            }
            return UsageFire(id: entry.id, kidID: kid.id, itemID: nil, minute: minute, firedAt: entry.at,
                             day: DayKey(entry.at, calendar: calendar), epochID: epoch?.id)
        }
    }
}

public enum ReplaySpeed: Codable, Sendable, Hashable {
    /// Upload everything at once.
    case instant
    /// Upload each record when the wall clock reaches its (shifted) time; past records go at once.
    case realTime
    /// Keep the recorded timestamps but deliver `factor` times faster, to watch alerts and pushes arrive.
    case accelerated(Double)
}

public enum Replay {
    /// Re-homes a trace onto another (fake) kid and day. Ids are derived deterministically from the new kid, so
    /// replaying the same trace twice overwrites rather than duplicates.
    public static func retarget(_ trace: Trace, to kid: Kid, day: DayKey, calendar: Calendar = .current) -> Trace {
        let shift = day.start(in: calendar).timeIntervalSince(trace.day.start(in: calendar))
        var itemMap: [UUID: UUID] = [:]
        let items = trace.items.map { item in
            var copy = item
            copy.id = TrackedItem.id(kid: kid.id, kind: item.kind, identifier: item.identifier)
            copy.kidID = kid.id
            copy.firstSeen = item.firstSeen.addingTimeInterval(shift)
            itemMap[item.id] = copy.id
            return copy
        }
        let epoch = trace.epoch.map { epoch in
            var copy = epoch
            copy.id = stableUUID(kid.id.uuidString, epoch.id.uuidString)
            copy.kidID = kid.id
            copy.startedAt = epoch.startedAt.addingTimeInterval(shift)
            return copy
        }
        let entries = trace.entries.map { entry in
            JournalEntry(id: stableUUID(kid.id.uuidString, day.description, entry.id.uuidString), kind: entry.kind,
                         activity: entry.activity, event: entry.event, at: entry.at.addingTimeInterval(shift))
        }
        let samples = trace.samples.map { sample in
            UsageSample(id: stableUUID(kid.id.uuidString, day.description, sample.id.uuidString), kidID: kid.id,
                        itemID: itemMap[sample.itemID] ?? sample.itemID, day: day,
                        start: sample.start.addingTimeInterval(shift), end: sample.end.addingTimeInterval(shift),
                        seconds: sample.seconds)
        }
        return Trace(kid: kid, day: day, items: items, epoch: epoch, entries: entries, samples: samples)
    }

    /// Delivery delays from `now` for records stamped at `times` (in order).
    public static func delays(for times: [Date], speed: ReplaySpeed, now: Date) -> [TimeInterval] {
        guard let first = times.min() else { return [] }
        return times.map { time in
            switch speed {
            case .instant: 0
            case .realTime: max(0, time.timeIntervalSince(now))
            case let .accelerated(factor): time.timeIntervalSince(first) / max(factor, 1)
            }
        }
    }

    public static func stableUUID(_ parts: String...) -> UUID {
        let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5-style
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
