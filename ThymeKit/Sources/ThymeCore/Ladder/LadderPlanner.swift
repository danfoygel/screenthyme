import Foundation

/// One DeviceActivity registration: a daily schedule holding the ladders for some items, or the total ladder.
public struct ActivityPlan: Sendable, Hashable {
    public var name: String
    public var itemIDs: [UUID]
    public var includesTotal: Bool
    /// Its items use the short (website) ladder.
    public var short = false

    public func eventCount(spec: LadderSpec) -> Int {
        itemIDs.count * spec.ladder(short: short).count + (includesTotal ? spec.totalMinutes.count : 0)
    }
}

/// The activities to register and the ladder they use, which may be shorter than requested (see `LadderPlanner`).
public struct LadderPlan: Sendable, Hashable {
    public var activities: [ActivityPlan]
    public var spec: LadderSpec

    public var isShortened: Bool { spec.itemMinutes.count < LadderSpec.standard.itemMinutes.count }
}

public enum LadderPlanError: LocalizedError, Equatable {
    case tooManyItems(items: Int, capacity: Int)
    case ladderLongerThanCap(events: Int, cap: Int)
    case noActivitiesFree(available: Int)

    public var errorDescription: String? {
        switch self {
        case let .tooManyItems(items, capacity):
            "The scan returned \(items) apps, sites and categories, but at most \(capacity) fit (20 schedules × the per-schedule event cap). Raise \"Max events per schedule\" in Debug."
        case let .ladderLongerThanCap(events, cap):
            "One ladder has \(events) events, more than the \(cap)-event cap per schedule."
        case let .noActivitiesFree(available):
            "Only \(available) of Apple's 20 monitoring schedules are free."
        }
    }
}

/// Splits items across activities so each stays under the per-activity event cap (unknown; S1 measures it).
/// When there are too many items for the full ladder, the item ladder is cut from the top (every 5 min to 60 is
/// always kept), trading tracking of very long daily use for coverage of every app.
public struct LadderPlanner: Sendable {
    public static let maxActivities = 20
    /// Item thresholds always kept: every 5 minutes up to 60.
    public static let minimumItemSteps = 12

    public var spec: LadderSpec
    public var maxEventsPerActivity: Int

    public init(spec: LadderSpec = .standard, maxEventsPerActivity: Int = 1000) {
        self.spec = spec
        self.maxEventsPerActivity = maxEventsPerActivity
    }

    /// Activity names start with `prefix(for:)`, so a heartbeat can tell which epoch's activities are still registered.
    public static func prefix(for epochID: UUID) -> String {
        "st.\(epochID.uuidString.prefix(8).lowercased())."
    }

    /// - Parameters:
    ///   - shortItemIDs: items on the short ladder (websites), packed into their own activities.
    ///   - inUse: activities that stay registered while this plan is added (the old epoch during a re-scan).
    public func plan(epochID: UUID, itemIDs: [UUID], shortItemIDs: [UUID] = [], inUse: Int = 0) throws -> LadderPlan {
        guard spec.totalMinutes.count <= maxEventsPerActivity else {
            throw LadderPlanError.ladderLongerThanCap(events: spec.totalMinutes.count, cap: maxEventsPerActivity)
        }
        let shortLadder = spec.ladder(short: true)
        guard shortLadder.count <= maxEventsPerActivity else {
            throw LadderPlanError.ladderLongerThanCap(events: shortLadder.count, cap: maxEventsPerActivity)
        }
        let available = Self.maxActivities - inUse
        guard available >= 2 else { throw LadderPlanError.noActivitiesFree(available: available) }
        let perShort = maxEventsPerActivity / shortLadder.count
        let shortActivities = (shortItemIDs.count + perShort - 1) / perShort
        let itemActivities = available - 1 - shortActivities  // one holds the total ladder
        guard itemActivities >= (itemIDs.isEmpty ? 0 : 1) else {
            throw LadderPlanError.tooManyItems(items: itemIDs.count + shortItemIDs.count,
                                               capacity: perShort * (available - 1))
        }

        // Longest item ladder (up to the full one) for which all items fit.
        var steps = spec.itemMinutes.count
        while steps >= Self.minimumItemSteps {
            let perActivity = maxEventsPerActivity / steps
            if perActivity > 0, itemIDs.count <= perActivity * itemActivities { break }
            steps -= 1
        }
        guard steps >= Self.minimumItemSteps else {
            let perActivity = maxEventsPerActivity / Self.minimumItemSteps
            throw LadderPlanError.tooManyItems(items: itemIDs.count + shortItemIDs.count,
                                               capacity: perActivity * itemActivities + perShort * shortActivities)
        }

        var used = spec
        used.itemMinutes = Array(spec.itemMinutes.prefix(steps))
        let prefix = Self.prefix(for: epochID)
        var activities = [ActivityPlan(name: prefix + "total", itemIDs: [], includesTotal: true)]
        let perActivity = maxEventsPerActivity / steps
        for start in stride(from: 0, to: itemIDs.count, by: perActivity) {
            let chunk = Array(itemIDs[start..<min(start + perActivity, itemIDs.count)])
            activities.append(ActivityPlan(name: prefix + "\(activities.count - 1)", itemIDs: chunk, includesTotal: false))
        }
        for start in stride(from: 0, to: shortItemIDs.count, by: perShort) {
            let chunk = Array(shortItemIDs[start..<min(start + perShort, shortItemIDs.count)])
            activities.append(ActivityPlan(name: prefix + "\(activities.count - 1)", itemIDs: chunk, includesTotal: false,
                                           short: true))
        }
        return LadderPlan(activities: activities, spec: used)
    }
}
