import Foundation
import Testing
@testable import ThymeCore

struct EnergyTests {
    func counters(_ millijoules: UInt64, cpuMs: UInt64 = 0, wakeups: UInt64 = 0) -> EnergyCounters {
        EnergyCounters(energyNanojoules: millijoules * 1_000_000, cpuNanoseconds: cpuMs * 1_000_000, wakeups: wakeups)
    }

    @Test func countsGrowthPerProcess() {
        var ledger = EnergyLedger()
        let process = UUID()
        ledger.record(counters(40, cpuMs: 10, wakeups: 3), process: process, source: .monitor, at: at(9, 0),
                      isCallback: true, calendar: utc)
        ledger.record(counters(55, cpuMs: 12, wakeups: 5), process: process, source: .monitor, at: at(9, 1),
                      isCallback: true, calendar: utc)

        let usage = ledger.usage(on: testDay, source: .monitor)
        #expect(usage.energyNanojoules == 55_000_000)  // the first sample counts in full: launch cost
        #expect(usage.cpuNanoseconds == 12_000_000)
        #expect(usage.wakeups == 5)
        #expect(usage.callbacks == 2)
        #expect(usage.launches == 1)
        #expect(ledger.usage(on: testDay, source: .app) == EnergyUsage())
    }

    @Test func separatesProcessesAndSources() {
        var ledger = EnergyLedger()
        let (first, second, app) = (UUID(), UUID(), UUID())
        ledger.record(counters(30), process: first, source: .monitor, at: at(9, 0), isCallback: true, calendar: utc)
        // A new extension process starts its counters from zero again.
        ledger.record(counters(20), process: second, source: .monitor, at: at(9, 5), isCallback: true, calendar: utc)
        ledger.record(counters(35), process: first, source: .monitor, at: at(9, 6), isCallback: true, calendar: utc)
        ledger.record(counters(500), process: app, source: .app, at: at(9, 7), isCallback: false, calendar: utc)

        let monitor = ledger.usage(on: testDay, source: .monitor)
        #expect(monitor.energyNanojoules == 55_000_000)
        #expect(monitor.launches == 2)
        #expect(monitor.callbacks == 3)
        let appUsage = ledger.usage(on: testDay, source: .app)
        #expect(appUsage.energyNanojoules == 500_000_000)
        #expect(appUsage.callbacks == 0)
    }

    @Test func growthGoesToTheSampleDay() {
        var ledger = EnergyLedger()
        let process = UUID()
        let tomorrow = testDay.adding(days: 1, calendar: utc)
        ledger.record(counters(10), process: process, source: .monitor, at: at(23, 59), isCallback: true, calendar: utc)
        ledger.record(counters(25), process: process, source: .monitor, at: at(24, 1), isCallback: true, calendar: utc)
        #expect(ledger.usage(on: testDay, source: .monitor).energyNanojoules == 10_000_000)
        #expect(ledger.usage(on: tomorrow, source: .monitor).energyNanojoules == 15_000_000)
        #expect(ledger.usage(on: tomorrow, source: .monitor).launches == 0)
    }

    @Test func prunesOldDaysAndProcesses() {
        var ledger = EnergyLedger()
        let old = UUID()
        ledger.record(counters(10), process: old, source: .monitor, at: at(9, 0), isCallback: true, calendar: utc)
        let later = at(9, 0).addingTimeInterval(Double(EnergyLedger.keepDays) * 86_400)
        ledger.record(counters(10), process: UUID(), source: .monitor, at: later, isCallback: true, calendar: utc)
        #expect(ledger.usage(on: testDay, source: .monitor) == EnergyUsage())
        #expect(ledger.processes[old] == nil)
        // A sample from the forgotten process would count in full again; that only happens if it lived for days.
        #expect(ledger.days.count == 1)
    }

    @Test func uploadsTodayAtMostEveryInterval() {
        var ledger = EnergyLedger()
        let process = UUID()
        ledger.record(counters(10), process: process, source: .monitor, at: at(9, 0), isCallback: true, calendar: utc)
        #expect(ledger.daysToUpload(now: at(9, 0), calendar: utc) == [testDay])

        ledger.markUploaded([testDay], at: at(9, 0))
        ledger.record(counters(20), process: process, source: .monitor, at: at(9, 5), isCallback: true, calendar: utc)
        #expect(ledger.daysToUpload(now: at(9, 5), calendar: utc) == [])
        #expect(ledger.daysToUpload(now: at(9, 15), calendar: utc) == [testDay])

        // Yesterday's final numbers go up right after midnight, whatever the interval.
        ledger.record(counters(30), process: process, source: .monitor, at: at(23, 59), isCallback: true, calendar: utc)
        ledger.markUploaded([testDay], at: at(23, 55))
        ledger.record(counters(31), process: process, source: .monitor, at: at(23, 59, 30), isCallback: true,
                      calendar: utc)
        #expect(ledger.daysToUpload(now: at(24, 0, 10), calendar: utc) == [testDay])
    }

    @Test func roundTripsThroughJSON() throws {
        var ledger = EnergyLedger()
        ledger.record(counters(10), process: UUID(), source: .app, at: at(9, 0), isCallback: false, calendar: utc)
        let decoded = try JSONDecoder.thyme.decode(EnergyLedger.self, from: JSONEncoder.thyme.encode(ledger))
        #expect(decoded.usage(on: testDay, source: .app) == ledger.usage(on: testDay, source: .app))
        #expect(decoded.processes.count == 1)
    }

    @Test func reportsShareOfBatteryForKnownPhones() {
        var monitor = EnergyUsage()
        monitor.energyNanojoules = 281_520_000_000  // 281.52 J = 1% of an iPhone SE's 7.82 Wh
        let kid = UUID()
        let report = EnergyReport(kidID: kid, day: testDay, updatedAt: at(12, 0), deviceModel: "iPhone14,6",
                                  monitor: monitor, app: EnergyUsage())
        #expect(abs((report.batteryFraction ?? 0) - 0.01) < 1e-9)
        #expect(report.id == EnergyReport(kidID: kid, day: testDay, updatedAt: at(13, 0), deviceModel: "",
                                          monitor: EnergyUsage(), app: EnergyUsage()).id)

        var unknown = report
        unknown.deviceModel = "iPhone99,1"
        #expect(unknown.batteryFraction == nil)
    }

    @Test func batteryComesFromTheNewerOfHeartbeatAndReports() {
        let kid = UUID()
        let heartbeat = Heartbeat(kidID: kid, at: at(9, 0), source: .launch, authStatus: "approved", activeActivities: [],
                                  expectedActivities: [], appVersion: "1", backlogCount: 0, lastFireAt: nil,
                                  batteryLevel: 0.9)
        let report = { (hour: Int, level: Double?) in
            EnergyReport(kidID: kid, day: testDay, updatedAt: at(hour, 0), deviceModel: "", monitor: EnergyUsage(),
                         app: EnergyUsage(), batteryLevel: level)
        }
        #expect(BatteryReading.latest(heartbeat: heartbeat, reports: [report(8, 0.95), report(11, 0.6)])
                == BatteryReading(level: 0.6, at: at(11, 0)))
        // A report without a level (an older build, or iOS didn't say) leaves the heartbeat's.
        #expect(BatteryReading.latest(heartbeat: heartbeat, reports: [report(11, nil)]) == BatteryReading(level: 0.9, at: at(9, 0)))
        #expect(BatteryReading.latest(heartbeat: nil, reports: []) == nil)

        let reading = BatteryReading(level: 0.2, at: at(9, 0))
        #expect(reading.isLow)
        #expect(reading.isRecent(now: at(10, 59)))
        #expect(!reading.isRecent(now: at(11, 0)))
    }

    @Test func reportsFromOlderBuildsDecodeWithoutBattery() throws {
        let report = EnergyReport(kidID: UUID(), day: testDay, updatedAt: at(12, 0), deviceModel: "", monitor: EnergyUsage(),
                                  app: EnergyUsage(), batteryLevel: 0.5)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder.thyme.encode(report)) as? [String: Any])
        json["batteryLevel"] = nil
        let old = try JSONDecoder.thyme.decode(EnergyReport.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.batteryLevel == nil)
        #expect(old.monitor == report.monitor)
    }
}
