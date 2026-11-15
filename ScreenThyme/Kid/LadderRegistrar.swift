import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings
import ThymeCore

/// Tokens are stored as JSON so they survive in the App Group and in CloudKit.
enum TokenCoding {
    static func encode<T: Encodable>(_ token: T) -> Data? {
        try? JSONEncoder().encode(token)
    }

    static func application(_ data: Data?) -> ApplicationToken? { decode(data) }
    static func webDomain(_ data: Data?) -> WebDomainToken? { decode(data) }
    static func category(_ data: Data?) -> ActivityCategoryToken? { decode(data) }

    private static func decode<T: Decodable>(_ data: Data?) -> T? {
        data.flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}

/// Registers the planned ladders with DeviceActivityCenter (PLAN.md §4.1).
enum LadderRegistrar {
    /// Daily, so every ladder resets at midnight.
    static var schedule: DeviceActivitySchedule {
        DeviceActivitySchedule(intervalStart: DateComponents(hour: 0, minute: 0),
                               intervalEnd: DateComponents(hour: 23, minute: 59), repeats: true)
    }

    /// Registers `epochID`'s activities and stops every other activity. Re-registering the same epoch replaces it.
    /// The old epoch keeps running until the new one is in place when both fit in Apple's 20 activities; otherwise
    /// it is stopped first, and `includesPastActivity` lets the new ladders catch up on today's use.
    static func register(items: [TrackedItem], kid: Kid, epochID: UUID, maxEventsPerActivity: Int,
                         spec: LadderSpec = .standard) throws -> LadderEpoch {
        let center = DeviceActivityCenter()
        let prefix = LadderPlanner.prefix(for: epochID)
        let others = center.activities.filter { !$0.rawValue.hasPrefix(prefix) }
        let planner = LadderPlanner(spec: spec, maxEventsPerActivity: maxEventsPerActivity)
        let plan = try planner.plan(epochID: epochID, itemIDs: items.map(\.id))
        let overlap = plan.activities.count + others.count <= LadderPlanner.maxActivities
        if !overlap {
            stop(others, center: center)
        }
        let spec = plan.spec
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

        var registered: [DeviceActivityName] = []
        do {
            for activity in plan.activities {
                var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
                if activity.includesTotal {
                    for minute in spec.totalMinutes {
                        events[.init(EventName.total(minute: minute))] = DeviceActivityEvent(
                            threshold: DateComponents(minute: minute), includesPastActivity: true)
                    }
                }
                for id in activity.itemIDs {
                    guard let item = byID[id] else { continue }
                    for minute in spec.itemMinutes {
                        guard let event = event(for: item, minute: minute) else { continue }
                        events[.init(EventName.item(id, minute: minute))] = event
                    }
                }
                let name = DeviceActivityName(activity.name)
                try center.startMonitoring(name, during: schedule, events: events)
                registered.append(name)
            }
        } catch {
            stop(registered, center: center)
            throw error
        }
        if overlap {
            stop(others, center: center)
        }
        recordRegistration(plan, center: center)
        return LadderEpoch(id: epochID, kidID: kid.id, startedAt: Date(), activityNames: plan.activities.map(\.name),
                           itemIDs: items.map(\.id), spec: spec)
    }

    /// `stopMonitoring([])` stops *every* activity, so an empty list must not reach it.
    static func stop(_ names: [DeviceActivityName], center: DeviceActivityCenter) {
        guard !names.isEmpty else { return }
        center.stopMonitoring(names)
    }

    /// S1(b): what we asked for vs what DeviceActivityCenter reports back, as a journal note.
    static func recordRegistration(_ plan: LadderPlan, center: DeviceActivityCenter) {
        let active = Set(center.activities.map(\.rawValue))
        let details = plan.activities.map { activity in
            let name = DeviceActivityName(activity.name)
            let kept = active.contains(activity.name) ? "\(center.events(for: name).count)" : "missing"
            return "\(activity.name.split(separator: ".").last ?? ""): \(activity.eventCount(spec: plan.spec))→\(kept)"
        }
        let text = "registered \(plan.activities.count), iOS reports \(active.count) active; " + details.joined(separator: ", ")
        try? AppGroup.journal.append(.note(text))
    }

    static func event(for item: TrackedItem, minute: Int) -> DeviceActivityEvent? {
        let threshold = DateComponents(minute: minute)
        switch item.kind {
        case .app:
            guard let token = TokenCoding.application(item.tokenData) else { return nil }
            return DeviceActivityEvent(applications: [token], threshold: threshold, includesPastActivity: true)
        case .domain:
            guard let token = TokenCoding.webDomain(item.tokenData) else { return nil }
            return DeviceActivityEvent(webDomains: [token], threshold: threshold, includesPastActivity: true)
        case .category:
            guard let token = TokenCoding.category(item.tokenData) else { return nil }
            return DeviceActivityEvent(categories: [token], threshold: threshold, includesPastActivity: true)
        }
    }
}
