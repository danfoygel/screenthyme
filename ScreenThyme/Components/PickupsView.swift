import SwiftUI
import ThymeCore

/// A kid's pickups and notifications in one day, by app and by hour: Apple's counts from the kid's phone
/// (`PickupReport`, PLAN.md §13).
struct PickupsView: View {
    @Environment(AppModel.self) private var model
    let kid: Kid
    @State var day: DayKey

    var body: some View {
        let items = model.data.items(for: kid.id)
        let report = model.data.pickups(kid: kid.id, day: day)
        List {
            Section {
                HStack {
                    Button { day = day.adding(days: -1) } label: { Image(systemName: "chevron.left") }
                    Spacer()
                    Text(day.start().formatted(date: .complete, time: .omitted))
                    Spacer()
                    Button { day = day.adding(days: 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(day >= DayKey(Date()))
                }
                .buttonStyle(.borderless)
                if let report {
                    PickupRows(report: report)
                }
            } footer: {
                if let report {
                    Text("Apple's counts as of \(report.updatedAt.formatted(date: .omitted, time: .shortened)). Apple counts a pickup under the first app opened after it.")
                }
            }
            if let report {
                Section {
                    ForEach(report.apps, id: \.itemID) { app in
                        ItemDetailsLink(item: items[app.itemID]) {
                            LabeledContent {
                                Text("\(app.pickups) · \(app.notifications)").monospacedDigit()
                            } label: {
                                // An app with notifications but no use yet has no item: named by its bundle ID.
                                ItemName(item: items[app.itemID]
                                    ?? TrackedItem(kidID: kid.id, kind: .app, identifier: app.bundleID, firstSeen: report.updatedAt))
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Apps")
                        Spacer()
                        Text("Pickups · Notifications")
                    }
                }
                Section {
                    ForEach(report.hours, id: \.start) { hour in
                        LabeledContent {
                            Text("\(hour.pickups) · \(hour.notifications)").monospacedDigit()
                        } label: { Text(hour.start.formatted(date: .omitted, time: .shortened)) }
                    }
                } header: {
                    HStack {
                        Text("By hour")
                        Spacer()
                        Text("Pickups · Notifications")
                    }
                }
            } else {
                Section { Text("No pickups or notifications recorded.").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Pickups")
        .bugButton(help: .pickups)
    }
}

/// A day's pickups, notifications and first pickup.
struct PickupRows: View {
    let report: PickupReport

    var body: some View {
        LabeledContent("Pickups", value: "\(report.pickups)")
        if report.pickupsWithoutApp > 0 {
            LabeledContent("Without opening an app", value: "\(report.pickupsWithoutApp)")
        }
        LabeledContent("Notifications", value: "\(report.notifications)")
        if let first = report.firstPickup {
            LabeledContent("First pickup", value: first.formatted(date: .omitted, time: .shortened))
        }
    }
}
