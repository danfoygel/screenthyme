import Darwin
import Foundation
import ThymeCore
import UIKit

/// Measures this process with the kernel's own per-task counters (the numbers behind Xcode's energy gauge) and adds
/// them to the day's `EnergyLedger` in the App Group. Sample after a callback's work, so the work is counted.
enum EnergyMeter {
    /// Counters restart with each process; this tells the ledger which process a sample came from.
    static let processID = UUID()

    static func record(_ source: EnergySource, isCallback: Bool, at date: Date = Date()) {
        guard let counters = sample() else { return }
        AppGroup.withLock("energy") {
            var ledger = load()
            ledger.record(counters, process: processID, source: source, at: date, isCallback: isCallback)
            save(ledger)
        }
    }

    /// Reports for days parents haven't seen yet, throttled (`EnergyLedger.daysToUpload`). Mark them uploaded after
    /// saving; samples recorded meanwhile stay pending, because each report remembers when it was taken.
    static func pendingReports(kid: Kid, now: Date = Date()) -> [EnergyReport] {
        let ledger = load()
        return ledger.daysToUpload(now: now).map { report(kid: kid, day: $0, ledger: ledger, now: now) }
    }

    static func markUploaded(_ reports: [EnergyReport]) {
        guard !reports.isEmpty else { return }
        AppGroup.withLock("energy") {
            var ledger = load()
            for report in reports { ledger.markUploaded([report.day], at: report.updatedAt) }
            save(ledger)
        }
    }

    static func report(kid: Kid, day: DayKey, now: Date = Date()) -> EnergyReport {
        report(kid: kid, day: day, ledger: load(), now: now)
    }

    private static func report(kid: Kid, day: DayKey, ledger: EnergyLedger, now: Date) -> EnergyReport {
        EnergyReport(kidID: kid.id, day: day, updatedAt: now, deviceModel: deviceModel,
                     monitor: ledger.usage(on: day, source: .monitor), app: ledger.usage(on: day, source: .app),
                     batteryLevel: batteryLevel())
    }

    /// The phone's charge, 0–1, or nil if iOS didn't say. `UIDevice` belongs to the main thread; off it (the extension's
    /// callbacks and uploads) this asks the main thread and waits briefly, never long enough to hold up an upload.
    static func batteryLevel() -> Double? {
        let read: @MainActor @Sendable () -> Double? = {
            UIDevice.current.isBatteryMonitoringEnabled = true
            let level = UIDevice.current.batteryLevel
            return level >= 0 ? Double(level) : nil
        }
        if Thread.isMainThread { return MainActor.assumeIsolated(read) }
        let box = BatteryBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            box.level = MainActor.assumeIsolated(read)
            done.signal()
        }
        return done.wait(timeout: .now() + 0.2) == .success ? box.level : nil
    }

    private final class BatteryBox: @unchecked Sendable {
        var level: Double?  // written before the semaphore's signal, read after its wait
    }

    /// `task_energy` is in nanojoules. The CPU times in the same struct are Mach ticks, so CPU time comes from
    /// `getrusage` instead.
    private static func sample() -> EnergyCounters? {
        var info = task_power_info_v2()
        var count = mach_msg_type_number_t(MemoryLayout<task_power_info_v2>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO_V2), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let nanoseconds = { (time: timeval) in UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_usec) * 1000 }
        #if arch(arm64)
        let energy = info.task_energy
        #else
        let energy: UInt64 = 0  // the kernel only reports energy on ARM (x86_64 simulators)
        #endif
        return EnergyCounters(energyNanojoules: energy,
                              cpuNanoseconds: nanoseconds(usage.ru_utime) + nanoseconds(usage.ru_stime),
                              wakeups: info.cpu_energy.task_interrupt_wakeups + info.cpu_energy.task_platform_idle_wakeups)
    }

    static let deviceModel: String = {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }()

    private static func load() -> EnergyLedger {
        guard let data = try? Data(contentsOf: AppGroup.energyLedgerURL),
              let ledger = try? JSONDecoder.thyme.decode(EnergyLedger.self, from: data) else { return EnergyLedger() }
        return ledger
    }

    private static func save(_ ledger: EnergyLedger) {
        try? JSONEncoder.thyme.encode(ledger).write(to: AppGroup.energyLedgerURL, options: .atomic)
    }
}
