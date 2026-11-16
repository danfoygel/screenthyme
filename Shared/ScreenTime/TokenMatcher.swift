import DeviceActivity
import Foundation
import ThymeCore

/// The token-matching events (PLAN.md §15.6): one activity, `tm`, with an event `m.<item id>` at one minute of use for
/// each scanned app not matched to Apple's data yet. Registered after a scan and on the first interval start of each
/// day, which drops the events of apps matched since; every registration loads Apple's daemon, so no more often.
enum TokenMatcher {
    static var activity: DeviceActivityName { DeviceActivityName("tm") }
    static let eventPrefix = "m."

    /// Apple's per-item seconds when the events were registered: each event counts use from then (midnight, on later
    /// days).
    struct State: Codable {
        var day: DayKey
        var baseline: [UUID: Double]
    }

    static var url: URL { AppGroup.container.appending(path: "token-match.json") }

    static func register(now: Date = Date()) {
        guard let kid = SharedConfig.load().kid else { return }
        let center = DeviceActivityCenter()
        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        for item in AppGroup.loadItems() where item.kind == .app && item.isScanned && item.match == nil {
            guard let token = TokenCoding.application(item.tokenData) else { continue }
            events[.init(eventPrefix + item.id.uuidString)] = DeviceActivityEvent(
                applications: [token], threshold: DateComponents(minute: Int(TokenMatching.threshold / 60)),
                includesPastActivity: false)
        }
        guard !events.isEmpty else {
            center.stopMonitoring([activity])
            return
        }
        AppGroup.save(State(day: DayKey(now), baseline: UsageSnapshot.todayUsage(kid: kid, now: now)), to: url)
        do {
            try center.startMonitoring(activity, during: Roller.schedule, events: events)
            try? AppGroup.journal.append(.note("token match: watching \(events.count) apps"))
        } catch {
            try? AppGroup.journal.append(.note("token match: registration failed: \(error)"))
        }
    }

    /// After a new authorization grant, which stops every activity.
    static func ensureRegistered() {
        if !DeviceActivityCenter().activities.contains(activity) { register() }
    }

    /// A new interval: at midnight, start over without the apps matched since. Our own registrations also start an
    /// interval; those find today's state and do nothing.
    static func intervalStarted(now: Date = Date()) {
        if let state = AppGroup.load(State.self, from: url), state.day == DayKey(now) { return }
        register(now: now)
    }

    /// An app reached a minute of use: find it in Apple's data.
    static func fired(_ event: String, kid: Kid, now: Date = Date()) {
        guard event.hasPrefix(eventPrefix), let itemID = UUID(uuidString: String(event.dropFirst(eventPrefix.count))) else { return }
        _ = Sampler.sampleBlocking(kid: kid)  // fresh numbers; takes the sampler lock itself
        let state = AppGroup.load(State.self, from: url)
        let baseline = state.flatMap { $0.day == DayKey(now) ? $0.baseline : nil } ?? [:]
        let usage = UsageSnapshot.todayUsage(kid: kid, now: now)
        AppGroup.withLock("sampler") {
            var items = AppGroup.loadItems()
            guard let index = items.firstIndex(where: { $0.id == itemID }), items[index].match == nil else {
                try? AppGroup.journal.append(.note("token match: unknown or already matched"))
                return
            }
            let taken = Set(items.compactMap(\.match))
            let candidates = Set(items.filter { $0.kind == .app && !$0.isScanned && !taken.contains($0.id) }.map(\.id))
            switch TokenMatching.match(baseline: baseline, usage: usage, candidates: candidates) {
            case let .matched(id):
                items[index].match = id
                AppGroup.saveItems(items)
                try? AppGroup.newItems.append(contentsOf: [items[index]])
                let name = items.first { $0.id == id }?.identifier ?? "?"
                try? AppGroup.journal.append(.note("token match: \(name)"))
            case .none:
                try? AppGroup.journal.append(.note("token match: no app near a minute"))
            case let .ambiguous(ids):
                try? AppGroup.journal.append(.note("token match: \(ids.count) apps near a minute, retrying tomorrow"))
            }
        }
    }
}
