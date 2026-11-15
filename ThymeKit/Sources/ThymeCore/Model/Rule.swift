import Foundation

/// Alert rules (PLAN.md §4.6). Edited on parent devices, evaluated on the kid device, except staleness.
public struct Rule: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kidID: UUID
    public var condition: RuleCondition
    public var enabled: Bool

    public init(id: UUID = UUID(), kidID: UUID, condition: RuleCondition, enabled: Bool = true) {
        self.id = id
        self.kidID = kidID
        self.condition = condition
        self.enabled = enabled
    }
}

/// All of one kid's rules in one record with a fixed name, so the kid's monitor extension can fetch it directly
/// (`RuleSet.<kid id>`) instead of depending on a silent push reaching the app.
public struct RuleSet: Codable, Sendable, Hashable {
    public var kidID: UUID
    public var rules: [Rule]
    public var updatedAt: Date

    public init(kidID: UUID, rules: [Rule], updatedAt: Date = Date()) {
        self.kidID = kidID
        self.rules = rules
        self.updatedAt = updatedAt
    }
}

public enum RuleCondition: Codable, Sendable, Hashable {
    /// Minutes of day; `endMinute < startMinute` wraps past midnight. `weekdays` uses Calendar numbering (1 = Sunday)
    /// and refers to the day the window starts. `repeatEvery` minutes between "still using" alerts.
    case quietHours(name: String, startMinute: Int, endMinute: Int, weekdays: Set<Int>, repeatEvery: Int)
    /// `itemID == nil` means total phone use.
    case dailyThreshold(itemID: UUID?, minutes: Int)
    case longSession(minutes: Int)
    /// An app or website never seen on this phone before is used.
    case newApp
    /// Evaluated on parent devices: no word from the kid device for `hours` during waking hours.
    case staleness(hours: Int, wakingStartMinute: Int, wakingEndMinute: Int)
}

extension RuleCondition {
    public var summary: String {
        switch self {
        case let .quietHours(name, start, end, _, _):
            "\(name): \(Self.clock(start))–\(Self.clock(end))"
        case let .dailyThreshold(itemID, minutes):
            itemID == nil ? "Phone over \(minutes) min/day" : "App over \(minutes) min/day"
        case let .longSession(minutes):
            "Session over \(minutes) min"
        case .newApp:
            "New app used"
        case let .staleness(hours, _, _):
            "No report for \(hours) h"
        }
    }

    public static func clock(_ minuteOfDay: Int) -> String {
        String(format: "%d:%02d", minuteOfDay / 60, minuteOfDay % 60)
    }
}
