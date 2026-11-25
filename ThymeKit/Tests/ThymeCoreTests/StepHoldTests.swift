import Foundation
import Testing
@testable import ThymeCore

/// A held stepper takes bigger, rounder steps the longer it's held; taps stay small.
struct StepHoldTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 0)

    /// When a held `Stepper` steps, measured in the Simulator: every 0.5 s, then every 0.1 s from 2.5 s.
    func repeats(for seconds: TimeInterval) -> [TimeInterval] {
        let tenths = Array(stride(from: 0, through: 25, by: 5)) + Array(26...300)
        return tenths.map { Double($0) / 10 }.filter { $0 <= seconds }
    }

    /// The values a held stepper shows from `value`, one per repeat, until `seconds` in.
    func hold(from value: Int, up: Bool = true, for seconds: TimeInterval) -> [Int] {
        var hold = StepHold.minutes
        var value = value
        return repeats(for: seconds).map {
            value = hold.step(value, up: up, in: 5...720, at: t0 + $0)
            return value
        }
    }

    @Test func tapsAreFiveMinutes() {
        var hold = StepHold.minutes
        #expect(hold.step(30, up: true, in: 5...720, at: t0) == 35)
        #expect(hold.step(35, up: true, in: 5...720, at: t0 + 0.7) == 40)
        #expect(hold.step(40, up: true, in: 5...720, at: t0 + 1.4) == 45)
        #expect(hold.step(45, up: true, in: 5...720, at: t0 + 2.1) == 50)
        #expect(hold.step(50, up: false, in: 5...720, at: t0 + 2.2) == 45)
    }

    @Test func aHoldSpeedsUpToRoundQuartersThenHalfHours() {
        let values = hold(from: 60, for: 6)
        #expect(values.prefix(6) == [65, 70, 75, 90, 105, 120])   // 1 s: 70 → the next quarter hour
        #expect(values[19] == 330)                                 // 3.9 s: 14 more quarters at 0.1 s
        #expect(values[20] == 360)                                 // 4 s: 330 → the next half hour
        #expect(values.last == 720)                                // stops at the top
        #expect(hold(from: 60, for: 5.3).last == 720)              // 12 hours in a little over 5 s
    }

    @Test func holdingDownRoundsDownToo() {
        #expect(hold(from: 200, up: false, for: 2) == [195, 190, 180, 165, 150])
        #expect(hold(from: 720, up: false, for: 6).last == 5)      // stops at the bottom
        var zero = StepHold.minutes
        #expect(zero.step(5, up: false, in: 0...720, at: t0) == 0)  // app limits go down to 0
    }

    @Test func turningAroundStartsANewHold() {
        var hold = StepHold.minutes
        var value = 100
        for t in repeats(for: 2) { value = hold.step(value, up: true, in: 5...720, at: t0 + t) }
        #expect(value == 150)                                      // 105, 110, 120, 135, 150
        #expect(hold.step(value, up: false, in: 5...720, at: t0 + 2.2) == 145)
    }
}
