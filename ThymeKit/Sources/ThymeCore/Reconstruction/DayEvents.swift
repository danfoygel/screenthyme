import Foundation

/// A moment in a kid's day that the calendar marks beside the use (`UsageCalendar`): a limit used up, one more minute,
/// a request for more time and its answer, a parent's alert.
public struct DayEvent: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case limitReached(LimitReached)
        case extraMinute(ExtraMinuteUse)
        /// The kid asked a parent; the answer is an event of its own.
        case asked(TimeRequest)
        /// A parent's answer, or the kid's own approval, to the request when it's known.
        case answered(TimeGrant, TimeRequest?)
        /// A parent ended an approval early (PLAN.md §15.12).
        case ended(TimeGrant)
        /// One of the parents' alert rules fired, or the phone lost data access.
        case alert(AlertRecord)
    }

    public var kind: Kind
    public var at: Date
    public var title: String

    public var id: String {
        switch kind {
        case let .limitReached(reached): "limit.\(reached.id)"
        case let .extraMinute(use): "minute.\(use.id)"
        case let .asked(request): "asked.\(request.id)"
        case let .answered(grant, _): "answered.\(grant.requestID)"
        case let .ended(grant): "ended.\(grant.requestID)"
        case let .alert(alert): "alert.\(alert.id)"
        }
    }

    /// What it named: the app or category, or nothing (the whole phone, a limit).
    public var itemID: UUID? {
        switch kind {
        case .limitReached: nil
        case let .extraMinute(use): use.itemID
        case let .asked(request): request.itemID
        case let .answered(grant, _), let .ended(grant): grant.itemID
        case let .alert(alert): alert.itemID
        }
    }
}

public enum DayEvents {
    /// The day's events, in time order. Alerts sent with a request or a self-approval are left out: those are events
    /// already. Of a grant's copies (a parent's end follows the answer), the ended one counts.
    /// - Parameter kidName: dropped from the front of alert titles ("Sam: long session" is "Long session").
    public static func build(day: DayKey, calendar: Calendar = .current, kidName: String? = nil,
                             limitsReached: [LimitReached], requests: [TimeRequest], grants: [TimeGrant],
                             extraMinutes: [ExtraMinuteUse], alerts: [AlertRecord]) -> [DayEvent] {
        func today(_ date: Date) -> Bool { DayKey(date, calendar: calendar) == day }
        let requestsByID = Dictionary(requests.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let answers = Dictionary(grants.map { ($0.requestID, $0) }, uniquingKeysWith: { a, b in b.endedAt != nil ? b : a })
            .values

        var events: [DayEvent] = []
        for reached in limitsReached where today(reached.at) {
            events.append(DayEvent(kind: .limitReached(reached), at: reached.at, title: "\(reached.name) limit reached"))
        }
        for use in extraMinutes where today(use.at) {
            events.append(DayEvent(kind: .extraMinute(use), at: use.at,
                                   title: use.minutes == 1 ? "One more minute" : "\(use.minutes) more minutes"))
        }
        for request in requests where today(request.at) {
            events.append(DayEvent(kind: .asked(request), at: request.at, title: request.reason == .alwaysAllow
                ? "Asked to always allow" : "Asked for \(MoreTime.describe(minutes: request.minutes))"))
        }
        for grant in answers {
            let request = requestsByID[grant.requestID]
            if today(grant.at) {
                events.append(DayEvent(kind: .answered(grant, request), at: grant.at, title: answerTitle(grant, request)))
            }
            if let ended = grant.endedAt, today(ended) {
                events.append(DayEvent(kind: .ended(grant), at: ended, title: "\(grant.endedBy ?? "A parent") ended it early"))
            }
        }
        for alert in alerts where today(alert.at)
        && TimeRequest.sent(with: alert, from: requests) == nil && TimeGrant.selfApproved(with: alert, from: grants) == nil {
            events.append(DayEvent(kind: .alert(alert), at: alert.at, title: alertTitle(alert.title, kidName: kidName)))
        }
        return events.sorted { ($0.at, $0.id) < ($1.at, $1.id) }
    }

    /// "Mom said yes", "Mom gave 30 more minutes", "Self-approved 20 more minutes".
    static func answerTitle(_ grant: TimeGrant, _ request: TimeRequest?) -> String {
        if grant.reason == .alwaysAllow { return grant.approved ? "\(grant.by) allowed it always" : "\(grant.by) said no" }
        if grant.isSelfApproved { return "Self-approved \(MoreTime.describe(minutes: grant.minutes))" }
        guard grant.approved else { return "\(grant.by) said no" }
        if let request, request.minutes == grant.minutes { return "\(grant.by) said yes" }
        return "\(grant.by) gave \(MoreTime.describe(minutes: grant.minutes))"
    }

    static func alertTitle(_ title: String, kidName: String?) -> String {
        guard let kidName, title.hasPrefix("\(kidName): ") else { return title }
        let rest = title.dropFirst(kidName.count + 2)
        return rest.prefix(1).uppercased() + rest.dropFirst()
    }

    /// Where to draw labels for markers at `positions` (in order, top to bottom): each at least `spacing` below the
    /// one before, so labels too close to read apart are pushed down.
    public static func spread(_ positions: [Double], spacing: Double) -> [Double] {
        var result: [Double] = []
        for position in positions {
            result.append(max(position, (result.last ?? -.infinity) + spacing))
        }
        return result
    }
}
