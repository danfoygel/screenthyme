import SwiftUI
import ThymeCore

/// One day of our own energy use on a kid's phone: the total, then what the extension and the app each used.
struct EnergyRows: View {
    let report: EnergyReport

    var body: some View {
        LabeledContent("Total", value: Format.energy(report.total, batteryFraction: report.batteryFraction))
        LabeledContent {
            Text(Format.energy(report.monitor)).monospacedDigit()
        } label: {
            Text("Tracking")
            Text("\(report.monitor.callbacks) wake-ups · \(Format.cpu(report.monitor)) CPU")
        }
        LabeledContent {
            Text(Format.energy(report.app)).monospacedDigit()
        } label: {
            Text("App")
            Text("\(report.app.launches) launches · \(Format.cpu(report.app)) CPU")
        }
    }
}

/// A kid phone's charge as a battery icon and percentage, red when low.
struct BatteryLabel: View {
    let reading: BatteryReading

    var body: some View {
        Label(Format.battery(reading.level), systemImage: symbol)
            .monospacedDigit()
            .foregroundStyle(reading.isLow ? .red : .secondary)
    }

    private var symbol: String {
        switch reading.level {
        case ..<0.13: "battery.0percent"
        case ..<0.38: "battery.25percent"
        case ..<0.63: "battery.50percent"
        case ..<0.88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

/// Every day the parent's phone has, newest first.
struct EnergyHistoryView: View {
    let reports: [EnergyReport]

    var body: some View {
        List(reports) { report in
            Section(report.day.description) {
                EnergyRows(report: report)
                LabeledContent("Updated", value: Format.relative(report.updatedAt))
            }
        }
        .navigationTitle("Battery use")
        .bugButton()
    }
}

extension Format {
    static func battery(_ level: Double) -> String {
        level.formatted(.percent.precision(.fractionLength(0)))
    }

    /// "0.4% of battery · 31 mWh", or "31 mWh" for phones whose battery size we don't know.
    static func energy(_ usage: EnergyUsage, batteryFraction: Double? = nil) -> String {
        let mWh = usage.milliwattHours
        let energy = mWh < 10 ? String(format: "%.1f mWh", mWh) : String(format: "%.0f mWh", mWh)
        guard let batteryFraction else { return energy }
        let percent = batteryFraction * 100
        let share = percent < 0.1 ? "<0.1%" : String(format: "%.1f%%", percent)
        return "\(share) of battery · \(energy)"
    }

    static func cpu(_ usage: EnergyUsage) -> String {
        let seconds = usage.cpuSeconds
        return seconds < 60 ? String(format: "%.1f s", seconds) : minutes(Int(seconds / 60))
    }
}
