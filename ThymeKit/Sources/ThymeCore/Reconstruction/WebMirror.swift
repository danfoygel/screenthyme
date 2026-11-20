import Foundation

/// Apps Apple's data reports for time on their website in Safari. On a kid's phone, Depop, Urban Outfitters, Amazon and
/// two New York Times apps had use though none was installed: every minute of theirs fell inside Safari's in the same
/// interval, and Apple listed no website for those shops. So that time counts twice in Apple's per-app numbers, as
/// Safari and as the app. All-apps totals leave these apps out; category limits still count them (Safari isn't in the
/// shop's category, and it's the only record of what was browsed). No scan lists them: they aren't installed.
public struct WebMirror: Codable, Sendable, Equatable {
    public static let browser = "com.apple.mobilesafari"
    /// The share of an app's seconds inside Safari's that makes it a website's.
    public static let share = 0.95
    /// The days that count, today included.
    public static let days = 7

    /// An app's seconds in a day, and how many of them fell inside Safari's in the same interval.
    public struct Seconds: Codable, Sendable, Equatable {
        public var all = 0.0
        public var inSafari = 0.0
    }

    /// Day → app item → its seconds.
    public var byDay: [DayKey: [UUID: Seconds]] = [:]

    public init() {}

    /// Adds samples from Apple's data. A fetch's samples for one hour share their interval, so an app's sample is
    /// compared with Safari's of the same day, start and end.
    public mutating func add(_ samples: some Sequence<UsageSample>, items: [UUID: TrackedItem]) {
        let byInterval = Dictionary(grouping: samples) { Interval(day: $0.day, start: $0.start, end: $0.end) }
        for (interval, samples) in byInterval {
            var seconds: [UUID: Double] = [:]
            for sample in samples { seconds[sample.itemID, default: 0] += sample.seconds }
            for (id, used) in seconds {
                guard let item = items[id], item.kind == .app, !item.isScanned, item.identifier != Self.browser else { continue }
                let safari = seconds[TrackedItem.id(kid: item.kidID, kind: .app, identifier: Self.browser)] ?? 0
                byDay[interval.day, default: [:]][id, default: Seconds()].all += used
                // A second and a half of slack: the two are fetched together but rounded apart.
                if used <= safari + 1.5 { byDay[interval.day, default: [:]][id, default: Seconds()].inSafari += used }
            }
        }
    }

    private struct Interval: Hashable {
        var day: DayKey
        var start: Date
        var end: Date
    }

    /// Forgets days before the last `days`.
    public mutating func prune(today: DayKey) {
        let first = today.adding(days: 1 - Self.days)
        byDay = byDay.filter { $0.key >= first }
    }

    /// The apps whose use over the last `days` was Safari's on their website. An app a scanned item with a token is
    /// matched to is installed, so it never is.
    public func mirrored(items: [UUID: TrackedItem], today: DayKey) -> Set<UUID> {
        let first = today.adding(days: 1 - Self.days)
        var total: [UUID: Seconds] = [:]
        for (day, apps) in byDay where day >= first && day <= today {
            for (id, seconds) in apps {
                total[id, default: Seconds()].all += seconds.all
                total[id, default: Seconds()].inSafari += seconds.inSafari
            }
        }
        let matched = TokenPairing.matchedIDs(Array(items.values))
        return Set(total.filter { id, seconds in
            seconds.all > 0 && seconds.inSafari >= Self.share * seconds.all && !matched.contains(id)
        }.keys)
    }
}
