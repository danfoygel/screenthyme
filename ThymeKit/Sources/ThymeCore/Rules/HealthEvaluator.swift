import Foundation

public enum HealthIssue: Sendable, Hashable {
    case neverReported
    case notAuthorized(status: String)
    /// Plain approval without data access: no per-app data, likely because Apple's Screen Time took it back
    /// (PLAN.md §15). Limits still apply, but by category and threshold only.
    case dataAccessLost
    case activitiesMissing([String])
    case stale(since: Date)
    case backlog(Int)

    public var isUrgent: Bool {
        switch self {
        case .notAuthorized, .dataAccessLost, .activitiesMissing, .stale: true
        case .neverReported, .backlog: false
        }
    }

    public var summary: String {
        switch self {
        case .neverReported: "Hasn't reported yet"
        case let .notAuthorized(status): "Screen Time access is \(status)"
        case .dataAccessLost: "No usage data access: was Screen Time set up in Settings?"
        case let .activitiesMissing(names): "\(names.count) monitoring schedule(s) missing"
        case let .stale(since): "Offline since \(since.formatted(date: .omitted, time: .shortened))"
        case let .backlog(count): "\(count) events waiting to upload"
        }
    }
}

/// Parent-side health checks on the latest heartbeat (PLAN.md §4.7).
public enum HealthEvaluator {
    public static let backlogWarning = 50
    /// The healthy `Heartbeat.authStatus`.
    public static let dataAccessStatus = "approved with data access"

    public static func issues(latest: Heartbeat?, lastFireAt: Date?, now: Date, staleHours: Int = 3,
                              wakingStartMinute: Int = 7 * 60, wakingEndMinute: Int = 22 * 60,
                              calendar: Calendar = .current) -> [HealthIssue] {
        guard let latest else {
            return lastFireAt == nil ? [.neverReported] : []
        }
        var issues: [HealthIssue] = []
        switch latest.authStatus {
        case dataAccessStatus: break
        case "approved": issues.append(.dataAccessLost)
        default: issues.append(.notAuthorized(status: latest.authStatus))
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
