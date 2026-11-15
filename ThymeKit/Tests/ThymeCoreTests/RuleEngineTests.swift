import Foundation
import Testing
@testable import ThymeCore

struct RuleEngineTests {
    let kid = testKid

    /// Feeds a trace's wakes through the engine, as the extension would.
    func run(_ trace: Trace, rules: [Rule], newItemsAt: [Date: [UUID]] = [:]) -> [AlertRecord] {
        let items = Dictionary(uniqueKeysWithValues: trace.items.map { ($0.id, $0) })
        let engine = RuleEngine(kidID: kid.id, kidName: kid.displayName, items: items, calendar: utc)
        var state = MonitorDayState(day: trace.day)
        var cumulative: [UUID: Double] = [:]
        let samplesByEnd = Dictionary(grouping: trace.samples, by: \.end)
        return trace.entries.flatMap { entry -> [AlertRecord] in
            guard let parsed = entry.parsedEvent else { return [] }
            var interval: [UUID: Double] = [:]
            for sample in samplesByEnd[entry.at] ?? [] {
                interval[sample.itemID, default: 0] += sample.seconds
                cumulative[sample.itemID, default: 0] += sample.seconds
            }
            let wake = WakeObservation(at: entry.at, totalMinute: parsed.minute, itemSeconds: cumulative,
                                       intervalSeconds: interval, newItems: newItemsAt[entry.at] ?? [])
            return engine.process(wake, state: &state, rules: rules)
        }
    }

    func near(_ date: Date, _ target: Date) -> Bool {
        date >= target && date.timeIntervalSince(target) <= 120
    }

    func id(_ name: String, in trace: Trace) -> UUID {
        trace.items.first { $0.name == name }!.id
    }

    @Test func quietHoursAlertsOnceThenRepeats() {
        let trace = SyntheticScenario.bedtime.trace(kid: kid, day: testDay, calendar: utc)
        let rule = Rule(kidID: kid.id, condition: .quietHours(name: "Bedtime", startMinute: 22 * 60, endMinute: 7 * 60,
                                                              weekdays: [], repeatEvery: 30))
        let alerts = run(trace, rules: [rule])
        let phone = alerts.filter { $0.itemID == nil }
        // First wake in the window 22:37, then "still" at the first wake 30+ min later (wakes come every 2 min of use).
        #expect(phone.map(\.at) == [at(22, 37), at(23, 7), at(23, 38)])
        #expect(Set(alerts.compactMap(\.itemID)) == [id("TikTok", in: trace), id("Minecraft", in: trace)])
    }

    @Test func quietWindowRespectsWeekdays() {
        let engine = RuleEngine(kidID: kid.id, kidName: "Emma", items: [:], calendar: utc)
        // 2026-11-14 is a Saturday (weekday 7); 01:00 on the 15th belongs to Saturday's window.
        #expect(engine.quietWindowStart(at: at(25, 0), start: 22 * 60, end: 7 * 60, weekdays: [7]) == at(22, 0))
        #expect(engine.quietWindowStart(at: at(25, 0), start: 22 * 60, end: 7 * 60, weekdays: [1]) == nil)
        #expect(engine.quietWindowStart(at: at(12, 0), start: 22 * 60, end: 7 * 60, weekdays: []) == nil)
        #expect(engine.quietWindowStart(at: at(9, 30), start: 8 * 60, end: 15 * 60, weekdays: []) == at(8, 0))
    }

    @Test func dailyThresholdsUseExactMinutes() {
        let trace = SyntheticScenario.schoolDay.trace(kid: kid, day: testDay, calendar: utc)
        let roblox = id("Roblox", in: trace)
        let rules = [
            Rule(kidID: kid.id, condition: .dailyThreshold(itemID: roblox, minutes: 60)),
            Rule(kidID: kid.id, condition: .dailyThreshold(itemID: nil, minutes: 120)),
        ]
        let alerts = run(trace, rules: rules)
        #expect(alerts.count == 2)
        // Total: 8 + 25 + 47 + 3 before Roblox, so minute 120 is Roblox's 37th, at 17:37; Roblox's 60th is at 18:00.
        // Alerts come at the first wake at or after that (one every 2 min of use).
        #expect(alerts[0].itemID == nil && near(alerts[0].at, at(17, 37)))
        #expect(alerts[1].itemID == roblox && near(alerts[1].at, at(18, 0)))
    }

    @Test func longSessionNamesDominantApp() {
        let trace = SyntheticScenario.schoolDay.trace(kid: kid, day: testDay, calendar: utc)
        let alerts = run(trace, rules: [Rule(kidID: kid.id, condition: .longSession(minutes: 45))])
        #expect(alerts.count == 2)
        #expect(alerts[0].itemID == id("YouTube", in: trace))
        #expect(alerts[1].itemID == id("Roblox", in: trace))
    }

    @Test func newAppAlerts() {
        let trace = SyntheticScenario.schoolDay.trace(kid: kid, day: testDay, calendar: utc)
        let tiktok = id("TikTok", in: trace)
        let firstTikTokWake = trace.samples.filter { $0.itemID == tiktok }.map(\.end).min()!
        let alerts = run(trace, rules: [Rule(kidID: kid.id, condition: .newApp)], newItemsAt: [firstTikTokWake: [tiktok]])
        #expect(alerts.map(\.itemID) == [tiktok])
        #expect(alerts.first?.body == "First time using TikTok.")
    }
}

struct HealthEvaluatorTests {
    let kidID = UUID()

    func heartbeat(at date: Date, auth: String = HealthEvaluator.dataAccessStatus, active: [String] = ["a", "b"]) -> Heartbeat {
        Heartbeat(kidID: kidID, at: date, source: .backgroundRefresh, authStatus: auth, activeActivities: active,
                  expectedActivities: ["a", "b"], appVersion: "1", backlogCount: 0, lastFireAt: nil)
    }

    @Test func staleOnlyDuringWakingHours() {
        let latest = heartbeat(at: at(8, 0))
        #expect(HealthEvaluator.issues(latest: latest, lastFireAt: nil, now: at(10, 0), calendar: utc).isEmpty)
        #expect(HealthEvaluator.issues(latest: latest, lastFireAt: nil, now: at(12, 0), calendar: utc)
            == [.stale(since: at(8, 0))])
        #expect(HealthEvaluator.issues(latest: latest, lastFireAt: at(11, 0), now: at(12, 0), calendar: utc).isEmpty)
        let evening = heartbeat(at: at(18, 0))
        #expect(HealthEvaluator.issues(latest: evening, lastFireAt: nil, now: at(23, 30), calendar: utc).isEmpty)
    }

    @Test func authorizationAndActivities() {
        let latest = heartbeat(at: at(10, 0), auth: "denied", active: ["a"])
        #expect(HealthEvaluator.issues(latest: latest, lastFireAt: nil, now: at(10, 5), calendar: utc)
            == [.notAuthorized(status: "denied"), .activitiesMissing(["b"])])
        #expect(HealthEvaluator.issues(latest: nil, lastFireAt: nil, now: at(10, 0), calendar: utc) == [.neverReported])
        #expect(HealthEvaluator.issues(latest: heartbeat(at: at(10, 0), auth: "approved"), lastFireAt: nil, now: at(10, 5),
                                       calendar: utc) == [.dataAccessLost])
    }
}
