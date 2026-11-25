import Foundation

/// A stepper held down: SwiftUI's `Stepper` repeats while it's held (every 0.5 s, then every 0.1 s from about 2.5 s
/// in), so steps less than `gap` apart in one direction are one hold, and the longer it's held the bigger each step.
/// Bigger steps land on multiples of themselves, so amounts stay round. A tap is always the smallest step.
public struct StepHold: Sendable {
    /// Each step size, from that many seconds into a hold.
    public let schedule: [(after: TimeInterval, step: Int)]
    /// Steps further apart than this are taps, not a hold.
    public let gap: TimeInterval

    private var start: Date?
    private var last: Date?
    private var up = true

    public init(schedule: [(after: TimeInterval, step: Int)], gap: TimeInterval = 0.6) {
        precondition(schedule.first?.after == 0, "a hold starts with the first step size")
        self.schedule = schedule
        self.gap = gap
    }

    /// Minutes: 5 at a time, then 15 after a second, then 30 after four (12 hours in about 5 s).
    public static var minutes: StepHold { StepHold(schedule: [(0, 5), (1, 15), (4, 30)]) }

    /// The value one step up or down from `value` at `now`, within `range`.
    public mutating func step(_ value: Int, up: Bool, in range: ClosedRange<Int>, at now: Date = .now) -> Int {
        if start == nil || up != self.up || last.map({ now.timeIntervalSince($0) >= gap }) ?? true { start = now }
        last = now
        self.up = up
        let held = now.timeIntervalSince(start!)
        let step = schedule.last { $0.after <= held }!.step
        let next = up ? (value / step + 1) * step : (value - 1) / step * step
        return min(max(next, range.lowerBound), range.upperBound)
    }
}
