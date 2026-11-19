import SwiftUI
import ThymeCore

/// Every usage sample for a day, grouped by the fetch that found it: "at 1:23:05 PM, YouTube +2 min".
/// Shown on the kid's Debug screen (this phone's outbox), in a parent's kid settings (the synced records), and for one
/// app from its details.
struct RawUsageView: View {
    let items: [UUID: TrackedItem]
    let samples: (DayKey) -> [UsageSample]
    @State var day: DayKey
    /// The app the samples were narrowed to, for the footer.
    var only: String?

    var body: some View {
        let reports = UsageReport.reports(samples(day))
        List {
            Section {
                HStack {
                    Button { day = day.adding(days: -1) } label: { Image(systemName: "chevron.left") }
                    Spacer()
                    Text(day.description).monospacedDigit()
                    Spacer()
                    Button { day = day.adding(days: 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(day >= DayKey(Date()))
                }
                .buttonStyle(.borderless)
            } footer: {
                if let only {
                    Text("\(reports.count) reports · \(Self.duration(reports.reduce(0) { $0 + $1.seconds })) in all. Each report is one fetch of Apple's numbers that found use of \(only); a row is what it gained since the fetch before.")
                } else {
                    Text("\(reports.count) reports · \(Self.duration(reports.reduce(0) { $0 + $1.seconds })) in all. Each report is one fetch of Apple's numbers; a row is what that app or site gained since the fetch before.")
                }
            }
            if reports.isEmpty {
                Text("No usage reported this day").foregroundStyle(.secondary)
            }
            ForEach(reports) { report in
                Section {
                    ForEach(report.samples) { sample in
                        HStack {
                            VStack(alignment: .leading) {
                                ItemName(item: items[sample.itemID])
                                Text("\(Format.time(sample.start))–\(Format.time(sample.end))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("+" + Self.duration(sample.seconds)).monospacedDigit()
                        }
                    }
                } header: {
                    HStack {
                        Text((report.exact ? "" : "≈ ") + report.at.formatted(date: .omitted, time: .standard))
                        Spacer()
                        Text("+" + Self.duration(report.seconds))
                    }
                    .monospacedDigit()
                }
            }
        }
        .navigationTitle("Raw usage")
        .bugButton()
    }

    /// "45 s", "2 min 10 s", "1 h 5 min".
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        if total < 3600 { return total % 60 == 0 ? "\(total / 60) min" : "\(total / 60) min \(total % 60) s" }
        return Format.minutes(total / 60)
    }
}
