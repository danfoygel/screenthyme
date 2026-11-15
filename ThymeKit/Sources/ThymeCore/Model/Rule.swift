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

public enum RuleCondition: Codable, Sendable, Hashable {
    /// Minutes of day; `endMinute < startMinute` wraps past midnight. `weekdays` uses Calendar numbering (1 = Sunday)
    /// and refers to the day the window starts. `repeatEvery` minutes between "still using" alerts.
    case quietHours(name: String, startMinute: Int, endMinute: Int, weekdays: Set<Int>, repeatEvery: Int)
    /// `itemID == nil` means total phone use.
    case dailyThreshold(itemID: UUID?, minutes: Int)
    case longSession(minutes: Int)
    /// In-use time today not explained by tracked apps' crossings: short uses and apps added since the last scan.
    case unexplainedUsage(minutes: Int)
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
        case let .unexplainedUsage(minutes):
            "Untracked use over \(minutes) min/day"
        case let .staleness(hours, _, _):
            "No report for \(hours) h"
        }
    }

    public static func clock(_ minuteOfDay: Int) -> String {
        String(format: "%d:%02d", minuteOfDay / 60, minuteOfDay % 60)
    }
}
