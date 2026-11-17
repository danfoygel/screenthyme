import Foundation

/// One fetch of Apple's per-app numbers: what each app and site gained since the fetch before (the Raw screen).
public struct UsageReport: Sendable, Hashable, Identifiable {
    public var at: Date
    /// False when the samples predate `UsageSample.reportedAt`: `at` is then their window's end, which is the fetch
    /// time unless the use fell in an earlier hour.
    public var exact: Bool
    /// Largest gain first.
    public var samples: [UsageSample]

    public var id: Date { at }
    public var seconds: Double { samples.reduce(0) { $0 + $1.seconds } }

    /// Groups samples by the fetch that found them, earliest fetch first.
    public static func reports(_ samples: [UsageSample]) -> [UsageReport] {
        Dictionary(grouping: samples) { $0.reportedAt ?? $0.end }
            .map { at, group in
                UsageReport(at: at, exact: group.allSatisfy { $0.reportedAt != nil },
                            samples: group.sorted { ($0.seconds, $0.start) > ($1.seconds, $1.start) })
            }
            .sorted { $0.at < $1.at }
    }
}
