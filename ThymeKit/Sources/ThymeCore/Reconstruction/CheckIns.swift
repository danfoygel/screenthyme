import Foundation

/// What the data says about a stretch of the day: how well use in it can be placed in time.
public enum Coverage: Sendable, Hashable {
    /// The wake alarm checked in on time: use here is placed to within one check-in (a minute of use).
    case placed
    /// Under 2 minutes of use since the previous check-in, or the wake alarm would have fired (it wakes every
    /// minute of use, every 2 before Nov 2026); that little use isn't drawn.
    case quiet
    /// Apple counted 2 or more minutes of use here, but no wake came: the alarm wasn't running.
    case blind
    /// The stretch ended in a burst of wake events: iOS's count ran ahead and was delivered at once, so its minutes
    /// have no time.
    case burst
}

public struct CoverageSpan: Sendable, Hashable {
    public var start: Date
    public var end: Date
    public var coverage: Coverage
}

/// Splits the day at its check-ins (wakes and fetches). Each stretch between two of them ends with `placed`
/// seconds whose time is known (an on-time wake: the use just before it), preceded by `rest`.
enum CheckIns {
    struct Stretch {
        var start: Date
        var end: Date
        /// Seconds at the end of the stretch that an on-time wake places.
        var placed: TimeInterval
        var rest: Coverage
        /// Samples reported at this stretch's closing check-in.
        var samples: [UsageSample]
    }

    /// Wake events closer together than this are one delivery.
    static let deliveryGap: TimeInterval = 30
    /// A delivery adding at most this many minutes is an on-time wake (a few steps of the alarm).
    static let onTimeMinutes = 4
    /// A wake and the fetch it ran, this close together, are one check-in.
    static let checkInGap: TimeInterval = 10
    /// Less use than this between check-ins is quiet: two steps of the wake alarm, one on days recorded at the
    /// old 2-minute steps.
    static let quietLimit: TimeInterval = 120

    static func stretches(_ input: DayInput) -> [Stretch] {
        // Deliveries and the minutes each adds (replays of minutes already seen add none).
        var deliveries: [(at: Date, added: Int)] = []
        var group: [FirePoint] = []
        var best = 0
        func close() {
            guard let last = group.last else { return }
            let top = group.map(\.minute).max() ?? 0
            deliveries.append((last.at, max(0, top - best)))
            best = max(best, top)
            group = []
        }
        for fire in input.total.sorted(by: { $0.at < $1.at }) {
            if let last = group.last, fire.at.timeIntervalSince(last.at) >= deliveryGap { close() }
            group.append(fire)
        }
        close()

        // Check-ins: every delivery and every fetch (not the hour cut-offs of samples from before `reportedAt`).
        let reported = { (sample: UsageSample) -> Date in sample.reportedAt ?? sample.end }
        var times = deliveries.map(\.at)
        for sample in input.samples {
            let at = reported(sample)
            if sample.reportedAt != nil || at.timeIntervalSince(input.dayStart).truncatingRemainder(dividingBy: 3600) != 0 {
                times.append(at)
            }
        }
        var clusters: [[Date]] = []
        for time in times.filter({ $0 > input.dayStart }).sorted() {
            if let last = clusters.last?.last, time.timeIntervalSince(last) < checkInGap {
                clusters[clusters.count - 1].append(time)
            } else {
                clusters.append([time])
            }
        }

        var stretches: [Stretch] = []
        var start = input.dayStart
        for cluster in clusters {
            guard let first = cluster.first, let end = cluster.last else { continue }
            let added = deliveries.filter { $0.at >= first && $0.at <= end }.reduce(0) { $0 + $1.added }
            let samples = input.samples.filter { reported($0) > start && reported($0) <= end && $0.seconds > 0 }
            let onTime = added > 0 && added <= onTimeMinutes
            let placed = onTime ? min(Double(added) * 60, end.timeIntervalSince(start)) : 0
            let counted = samples.filter { !input.websites.contains($0.itemID) }.reduce(0) { $0 + $1.seconds }
            let rest: Coverage = added > onTimeMinutes ? .burst : counted - placed >= quietLimit ? .blind : .quiet
            stretches.append(Stretch(start: start, end: end, placed: placed, rest: rest, samples: samples))
            start = end
        }
        return stretches
    }

    static func coverage(_ stretches: [Stretch]) -> [CoverageSpan] {
        var spans: [CoverageSpan] = []
        func add(_ start: Date, _ end: Date, _ coverage: Coverage) {
            guard end > start else { return }
            if let last = spans.last, last.coverage == coverage, last.end == start {
                spans[spans.count - 1].end = end
            } else {
                spans.append(CoverageSpan(start: start, end: end, coverage: coverage))
            }
        }
        for stretch in stretches {
            let placedStart = stretch.end.addingTimeInterval(-stretch.placed)
            add(stretch.start, placedStart, stretch.rest)
            add(placedStart, stretch.end, .placed)
        }
        return spans
    }

    /// Use each stretch's on-time wake places goes on its last minutes, shared among the apps reported there. Use
    /// beyond that is dropped in a quiet stretch; in a blind or burst one it's drawn at a best guess: back to back,
    /// most-used app last, ending where its sample's window does (or where the placed minutes begin). A web app's
    /// pieces carry the websites' use in the same fetch that its own time can account for.
    static func pieces(_ stretches: [Stretch], websites: Set<UUID>, webApps: Set<UUID> = []) -> [UsageBlock] {
        var pieces: [UsageBlock] = []
        for stretch in stretches {
            let counted = stretch.samples.filter { !websites.contains($0.itemID) }.reduce(0) { $0 + $1.seconds }
            let share = counted > 0 ? min(1, stretch.placed / counted) : 0
            let placedStart = stretch.end.addingTimeInterval(-stretch.placed)
            var guessEnds: [DateInterval: Date] = [:]
            let ordered = stretch.samples.sorted { ($0.seconds, $0.itemID.uuidString) > ($1.seconds, $1.itemID.uuidString) }
            for sample in ordered {
                let siteUse = webApps.contains(sample.itemID) ? sites(for: sample, in: stretch, websites: websites) : [:]
                let onPlaced = sample.seconds * share
                if onPlaced > 0 {
                    pieces.append(UsageBlock(itemID: sample.itemID, start: placedStart, end: stretch.end,
                                             seconds: onPlaced, siteSeconds: siteUse.mapValues { $0 * share }))
                }
                let left = sample.seconds - onPlaced
                guard stretch.rest != .quiet, left >= 1 else { continue }
                let window = DateInterval(start: min(sample.start, sample.end), end: sample.end)
                let end = guessEnds[window] ?? max(window.start, min(window.end, placedStart))
                let start = max(window.start, end.addingTimeInterval(-left))
                pieces.append(UsageBlock(itemID: sample.itemID, start: start, end: max(end, start.addingTimeInterval(1)),
                                         seconds: left, somewhereIn: window,
                                         siteSeconds: siteUse.mapValues { $0 * (1 - share) }))
                guessEnds[window] = start
            }
        }
        return pieces
    }

    /// Each website's use in the web app sample's fetch (the same window), up to the web app's own seconds.
    static func sites(for sample: UsageSample, in stretch: Stretch, websites: Set<UUID>) -> [UUID: Double] {
        var sites: [UUID: Double] = [:]
        for site in stretch.samples where websites.contains(site.itemID)
            && abs(site.start.timeIntervalSince(sample.start)) < 1 && abs(site.end.timeIntervalSince(sample.end)) < 1 {
            sites[site.itemID, default: 0] += min(sample.seconds, site.seconds)
        }
        return sites
    }
}
