import Foundation

/// How much more time a kid asks for and a parent gives (PLAN.md §15.4): any of `steps` minutes, or nil for the rest of
/// today (until Downtime ends, for Downtime).
public enum MoreTime {
    /// What the stepper offers, in minutes.
    public static let steps = [5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240]

    /// The step after `minutes` (`up`) or before it; past either end it stays at that end.
    public static func step(_ minutes: Int, up: Bool) -> Int {
        up ? steps.first { $0 > minutes } ?? steps.last! : steps.last { $0 < minutes } ?? steps.first!
    }

    /// "20 more minutes", "1 more hour", "1 h 30 min more", "the rest of today".
    public static func describe(minutes: Int?) -> String {
        guard let minutes else { return "the rest of today" }
        let (hours, rest) = minutes.quotientAndRemainder(dividingBy: 60)
        switch (hours, rest) {
        case (0, 1): return "1 more minute"
        case (0, _): return "\(minutes) more minutes"
        case (1, 0): return "1 more hour"
        case (_, 0): return "\(hours) more hours"
        default: return "\(hours) h \(rest) min more"
        }
    }

    /// The choice that has no amount: Downtime and breaks end on their own.
    public static func restLabel(for reason: BlockReason) -> String {
        if case .downtime = reason { return "Until Downtime ends" }
        if reason == .breakTime { return "Until the break ends" }
        return "The rest of today"
    }

    /// What was asked and what the parent answered: "Asked for 1 more hour · Mom gave 30 more minutes".
    public static func outcome(of request: TimeRequest, answer: TimeGrant?) -> String {
        if request.reason == .alwaysAllow {
            guard let answer else { return "Not answered yet" }
            return answer.approved ? "\(answer.by) said yes" : "\(answer.by) said no"
        }
        let asked = "Asked for \(describe(minutes: request.minutes))"
        guard let answer else { return asked + " · not answered yet" }
        let ended = answer.endedBy.map { " · \($0) ended it early" } ?? ""
        if answer.isSelfApproved { return asked + " · self-approved, no parent answered" + ended }
        guard answer.approved else { return asked + " · \(answer.by) said no" }
        return (answer.minutes == request.minutes ? asked + " · \(answer.by) said yes"
            : asked + " · \(answer.by) gave \(describe(minutes: answer.minutes))") + ended
    }
}

extension TimeRequest {
    /// The request `alert` was sent with: the kid's phone writes both at the same moment, for the same item.
    public static func sent(with alert: AlertRecord, from requests: some Sequence<TimeRequest>) -> TimeRequest? {
        guard alert.ruleID == nil else { return nil }
        return requests.first {
            $0.kidID == alert.kidID && $0.itemID == alert.itemID && abs($0.at.timeIntervalSince(alert.at)) < 1
        }
    }
}
