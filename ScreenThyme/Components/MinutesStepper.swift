import SwiftUI
import ThymeCore

/// A stepper over minutes that speeds up while held: 5 at a time, then 15, then an hour (`StepHold.minutes`).
struct MinutesStepper<Label: View>: View {
    @Binding var minutes: Int
    var range: ClosedRange<Int> = 5...720
    @ViewBuilder let label: () -> Label
    @State private var hold = StepHold.minutes

    var body: some View {
        Stepper(label: label) {
            minutes = hold.step(minutes, up: true, in: range)
        } onDecrement: {
            minutes = hold.step(minutes, up: false, in: range)
        }
    }
}

extension MinutesStepper where Label == Text {
    init(_ title: String, minutes: Binding<Int>, range: ClosedRange<Int> = 5...720) {
        self.init(minutes: minutes, range: range) { Text(title) }
    }
}
