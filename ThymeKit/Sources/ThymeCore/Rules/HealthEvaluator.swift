import Foundation

public enum HealthIssue: Sendable, Hashable {
    case neverReported
    case notAuthorized(status: String)
    case activitiesMissing([String])
    case stale(since: Date)
    case backlog(Int)

    public var isUrgent: Bool {
        switch self {
        case .notAuthorized, .activitiesMissing, .stale: true
        case .neverReported, .backlog: false
        }
    }

    public var summary: String {
        switch self {
        case .neverReported: "Hasn't reported yet"
        case let .notAuthorized(status): "Screen Time access is \(status)"
        case let .activitiesMissing(names): "\(names.count) monitoring schedule(s) missing"
        case let .stale(since): "Offline since \(since.formatted(date: .omitted, time: .shortened))"
        case let .backlog(count): "\(count) events waiting to upload"
        }
    }
}

/// Parent-side health checks on the latest heartbeat (PLAN.md §4.7).
public enum HealthEvaluator {
    public static let backlogWarning = 50

    public static func issues(latest: Heartbeat?, lastFireAt: Date?, now: Date, staleHours: Int = 3,
                              wakingStartMinute: Int = 7 * 60, wakingEndMinute: Int = 22 * 60,
                              calendar: Calendar = .current) -> [HealthIssue] {
        guard let latest else {
            return lastFireAt == nil ? [.neverReported] : []
        }
        var issues: [HealthIssue] = []
        if latest.authStatus != "approved" {
            issues.append(.notAuthorized(status: latest.authStatus))
        }
        let missing = latest.expectedActivities.filter { !latest.activeActivities.contains($0) }
        if !missing.isEmpty {
            issues.append(.activitiesMissing(missing))
        }
        let lastHeard = max(latest.at, lastFireAt ?? .distantPast)
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let minuteOfDay = parts.hour! * 60 + parts.minute!
        let waking = minuteOfDay >= wakingStartMinute && minuteOfDay < wakingEndMinute
        if waking, now.timeIntervalSince(lastHeard) > Double(staleHours) * 3600 {
            issues.append(.stale(since: lastHeard))
        }
        if latest.backlogCount >= backlogWarning {
            issues.append(.backlog(latest.backlogCount))
        }
        return issues
    }
}
