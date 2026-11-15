import Foundation

/// DeviceActivityEvent names carry everything the extension needs: "i.<itemUUID>.<minute>" or "t.<minute>".
public enum EventName {
    public struct Parsed: Sendable, Hashable {
        /// nil for the total ladder.
        public var itemID: UUID?
        public var minute: Int
    }

    public static func item(_ id: UUID, minute: Int) -> String {
        "i.\(id.uuidString).\(minute)"
    }

    public static func total(minute: Int) -> String {
        "t.\(minute)"
    }

    public static func parse(_ raw: String) -> Parsed? {
        let parts = raw.split(separator: ".")
        switch (parts.first, parts.count) {
        case ("t", 2):
            guard let minute = Int(parts[1]) else { return nil }
            return Parsed(itemID: nil, minute: minute)
        case ("i", 3):
            guard let id = UUID(uuidString: String(parts[1])), let minute = Int(parts[2]) else { return nil }
            return Parsed(itemID: id, minute: minute)
        default:
            return nil
        }
    }

    /// Rewrites the item id in an item event name; total names pass through.
    public static func remap(_ raw: String, items: [UUID: UUID]) -> String {
        guard let parsed = parse(raw), let id = parsed.itemID, let mapped = items[id] else { return raw }
        return item(mapped, minute: parsed.minute)
    }
}
