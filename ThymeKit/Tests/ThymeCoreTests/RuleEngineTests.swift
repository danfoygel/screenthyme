import Foundation
import Testing
@testable import ThymeCore

struct RuleEngineTests {
    let kid = Kid(displayName: "Emma")

    func run(_ trace: Trace, rules: [Rule]) -> [AlertRecord] {
        let items = Dictionary(uniqueKeysWithValues: trace.items.map { ($0.id, $0) })
        let engine = RuleEngine(kidID: kid.id, kidName: kid.displayName, items: items, calendar: utc)
        var state = MonitorDayState(day: trace.day)
        return trace.entries.flatMap { entry in
            engine.process(entry.parsedEvent!, at: entry.at, state: &state, rules: rules)
        }
    }

    func id(_ name: String, in trace: Trace) -> UUID {
        trace.items.first { $0.nickname == name }!.id
    }

    @Test func quietHoursAlertsOnceThenRepeats() {
        let trace = SyntheticScenario.bedtime.trace(kid: kid, day: testDay, calendar: utc)
        let rule = Rule(kidID: kid.id, condition: .quietHours(name: "Bedtime", startMinute: 22 * 60, endMinute: 7 * 60,
                                                              weekdays: [], repeatEvery: 30))
        let alerts = run(trace, rules: [rule])
        let phone = alerts.filter { $0.itemID == nil }
        // 22:36 first use, then "still" at 23:06 and 23:36 (use ends 23:50).
        #expect(phone.map(\.at) == [at(22, 36), at(23, 6), at(23, 36)])
        let apps = Set(alerts.compactMap(\.itemID))
        #expect(apps == [id("TikTok", in: trace), id("Minecraft", in: trace)])
        #expect(!alerts.contains { $0.itemID == id("YouTube", in: trace) })
    }

    @Test func quietWindowRespectsWeekdays() {
        let engine = RuleEngine(kidID: kid.id, kidName: "Emma", items: [:], calendar: utc)
        // 2026-11-14 is a Saturday (weekday 7); 01:00 on the 15th belongs to Saturday's window.
        #expect(engine.quietWindowStart(at: at(25, 0), start: 22 * 60, end: 7 * 60, weekdays: [7]) == at(22, 0))
        #expect(engine.quietWindowStart(at: at(25, 0), start: 22 * 60, end: 7 * 60, weekdays: [1]) == nil)
        #expect(engine.quietWindowStart(at: at(12, 0), start: 22 * 60, end: 7 * 60, weekdays: []) == nil)
        #expect(engine.quietWindowStart(at: at(9, 30), start: 8 * 60, end: 15 * 60, weekdays: []) == at(8, 0))
    }

    @Test func dailyThresholdFiresOnce() {
        let trace = SyntheticScenario.schoolDay.trace(kid: kid, day: testDay, calendar: utc)
        let roblox = id("Roblox", in: trace)
        let rules = [
            Rule(kidID: kid.id, condition: .dailyThreshold(itemID: roblox, minutes: 60)),
            Rule(kidID: kid.id, condition: .dailyThreshold(itemID: nil, minutes: 120)),
        ]
        let alerts = run(trace, rules: rules)
        #expect(alerts.count == 2)
        // Total: 8 + 25 + 47 + 3 before Roblox, so minute 120 is Roblox's 37th, at 17:37.
        #expect(alerts[0].itemID == nil && alerts[0].at == at(17, 37))
        #expect(alerts[1].itemID == roblox && alerts[1].at == at(18, 0, 0.5))
    }

    @Test func longSessionNamesDominantApp() {
        let trace = SyntheticScenario.schoolDay.trace(kid: kid, day: testDay, calendar: utc)
        let alerts = run(trace, rules: [Rule(kidID: kid.id, condition: .longSession(minutes: 45))])
        // Runs: Classroom 25, YouTube 47, untracked 3, Roblox 65 (each gap > 2 min). Two are over 45.
        #expect(alerts.count == 2)
        #expect(alerts[0].itemID == id("YouTube", in: trace))
        #expect(alerts[1].itemID == id("Roblox", in: trace))
    }

    @Test func unexplainedUsage() {
        let tracked = UUID()
        let entries = SyntheticTrace.entries(sessions: [
            SyntheticSession(item: tracked, start: at(10, 0), minutes: 10),
            SyntheticSession(item: nil, start: at(11, 0), minutes: 20),
        ])
        let item = TrackedItem(id: tracked, kidID: kid.id, kind: .app, tokenData: nil, ordinal: 1, firstSeenEpoch: UUID())
        let trace = Trace(kid: kid, day: testDay, items: [item], epoch: nil, entries: entries)
        let alerts = run(trace, rules: [Rule(kidID: kid.id, condition: .unexplainedUsage(minutes: 15))])
        // Explained = 10 + 4 remainder = 14; total reaches 14 + 15 = 29 at 11:19.
        #expect(alerts.map(\.at) == [at(11, 19)])
    }

    @Test func newDayResetsState() {
        let engine = RuleEngine(kidID: kid.id, kidName: "Emma", items: [:], calendar: utc)
        var state = MonitorDayState(day: testDay)
        let rule = Rule(kidID: kid.id, condition: .dailyThreshold(itemID: nil, minutes: 1))
        #expect(engine.process(.init(itemID: nil, minute: 1), at: at(10, 0), state: &state, rules: [rule]).count == 1)
        #expect(engine.process(.init(itemID: nil, minute: 2), at: at(10, 1), state: &state, rules: [rule]).isEmpty)
        #expect(engine.process(.init(itemID: nil, minute: 1), at: at(34, 0), state: &state, rules: [rule]).count == 1)
        #expect(state.day == testDay.adding(days: 1, calendar: utc))
    }
}

struct HealthEvaluatorTests {
    let kidID = UUID()

    func heartbeat(at date: Date, auth: String = "approved", active: [String] = ["a", "b"]) -> Heartbeat {
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
    }
}
