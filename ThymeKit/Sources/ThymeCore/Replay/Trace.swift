import CryptoKit
import Foundation

/// One recorded (or synthesized) day of a kid's journal: the replay tool's unit (PLAN.md §7.2).
public struct Trace: Codable, Sendable {
    public var version = 1
    public var kid: Kid
    public var day: DayKey
    public var items: [TrackedItem]
    public var epoch: LadderEpoch?
    public var entries: [JournalEntry]

    public init(kid: Kid, day: DayKey, items: [TrackedItem], epoch: LadderEpoch?, entries: [JournalEntry]) {
        self.kid = kid
        self.day = day
        self.items = items
        self.epoch = epoch
        self.entries = entries
    }

    public func encoded() throws -> Data {
        try JSONEncoder.thyme.encode(self)
    }

    public static func decode(_ data: Data) throws -> Trace {
        try JSONDecoder.thyme.decode(Trace.self, from: data)
    }

    /// The trace's thresholds as synced records.
    public func fires(calendar: Calendar = .current) -> [UsageFire] {
        entries.compactMap { entry in
            guard entry.kind == .threshold, let parsed = entry.parsedEvent else { return nil }
            return UsageFire(id: entry.id, kidID: kid.id, itemID: parsed.itemID, minute: parsed.minute,
                             firedAt: entry.at, day: DayKey(entry.at, calendar: calendar), epochID: epoch?.id)
        }
    }
}

public enum ReplaySpeed: Codable, Sendable, Hashable {
    /// Upload everything at once.
    case instant
    /// Upload each fire when the wall clock reaches its (shifted) time; past fires go at once.
    case realTime
    /// Keep the recorded timestamps but deliver `factor` times faster, to watch alerts and pushes arrive.
    case accelerated(Double)
}

public enum Replay {
    /// Re-homes a trace onto another (fake) kid and day. Item and entry ids are derived deterministically from the new
    /// kid, so replaying the same trace twice overwrites rather than duplicates, and several days stay consistent.
    public static func retarget(_ trace: Trace, to kid: Kid, day: DayKey, calendar: Calendar = .current) -> Trace {
        let shift = day.start(in: calendar).timeIntervalSince(trace.day.start(in: calendar))
        var itemMap: [UUID: UUID] = [:]
        for item in trace.items {
            itemMap[item.id] = stableUUID(kid.id.uuidString, item.id.uuidString)
        }
        let items = trace.items.map { item in
            var copy = item
            copy.id = itemMap[item.id]!
            copy.kidID = kid.id
            return copy
        }
        let epoch = trace.epoch.map { epoch in
            var copy = epoch
            copy.id = stableUUID(kid.id.uuidString, epoch.id.uuidString)
            copy.kidID = kid.id
            copy.startedAt = epoch.startedAt.addingTimeInterval(shift)
            copy.itemIDs = epoch.itemIDs.map { itemMap[$0] ?? $0 }
            return copy
        }
        let entries = trace.entries.map { entry in
            JournalEntry(id: stableUUID(kid.id.uuidString, day.description, entry.id.uuidString),
                         kind: entry.kind,
                         activity: entry.activity,
                         event: entry.event.map { EventName.remap($0, items: itemMap) },
                         at: entry.at.addingTimeInterval(shift))
        }
        return Trace(kid: kid, day: day, items: items, epoch: epoch, entries: entries)
    }

    /// Delivery delays from `now` for each fire.
    public static func schedule(_ fires: [UsageFire], speed: ReplaySpeed, now: Date) -> [(delay: TimeInterval, fire: UsageFire)] {
        let sorted = fires.sorted { $0.firedAt < $1.firedAt }
        guard let first = sorted.first?.firedAt else { return [] }
        return sorted.map { fire in
            let delay: TimeInterval = switch speed {
            case .instant: 0
            case .realTime: max(0, fire.firedAt.timeIntervalSince(now))
            case let .accelerated(factor): fire.firedAt.timeIntervalSince(first) / max(factor, 1)
            }
            return (delay, fire)
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
