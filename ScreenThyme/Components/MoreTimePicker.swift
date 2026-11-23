import SwiftUI
import ThymeCore

/// How much more time: a stepper over `MoreTime.steps`, or the rest of today (nil). The kid asks with it and a parent
/// changes the answer with it.
struct MoreTimePicker: View {
    @Binding var minutes: Int?
    /// "The rest of today", or "Until Downtime ends".
    let restLabel: String
    /// The stepper's amount, kept while the rest of today is on.
    @State private var amount: Int

    init(minutes: Binding<Int?>, restLabel: String) {
        _minutes = minutes
        self.restLabel = restLabel
        _amount = State(initialValue: minutes.wrappedValue ?? 15)
    }

    var body: some View {
        Stepper {
            Text(MoreTime.describe(minutes: amount).capitalizedFirst)
                .foregroundStyle(minutes == nil ? .secondary : .primary)
        } onIncrement: {
            set(MoreTime.step(amount, up: true))
        } onDecrement: {
            set(MoreTime.step(amount, up: false))
        }
        .disabled(minutes == nil)
        Toggle(restLabel, isOn: Binding(get: { minutes == nil }, set: { minutes = $0 ? nil : amount }))
    }

    private func set(_ new: Int) {
        amount = new
        minutes = new
    }
}
