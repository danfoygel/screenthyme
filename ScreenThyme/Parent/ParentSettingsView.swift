import CloudKit
import SwiftUI
import ThymeCore
import UIKit

struct ParentSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var share: CKShare?
    @State private var preparingShare = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let family = model.config.family {
                        LabeledContent("Family", value: family.isOwner ? "You own it" : "Joined")
                        if family.isOwner {
                            Button(preparingShare ? "Preparing…" : "Invite parent or kid") {
                                Task {
                                    preparingShare = true
                                    defer { preparingShare = false }
                                    do { share = try await FamilyService.share(for: family) } catch { model.show(error) }
                                }
                            }
                        }
                    } else {
                        Button("Create family") { Task { await model.createFamily() } }
                        Text("Or open the invite link from the parent who created it.").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Family")
                } footer: {
                    Text("Invite the other parent and each kid's Apple Account with read/write permission. Kids open the link on their own phone.")
                }
                Section("Kids") {
                    ForEach(model.data.sortedKids) { kid in
                        NavigationLink(kid.displayName) { KidSettingsView(kid: kid) }
                    }
                }
                Section {
                    Button("Allow notifications") { Task { await Notifier.requestPermission() } }
                    Button("Re-install push subscriptions") { Task { await model.reinstallSubscriptions() } }
                }
                TestModeSection()
            }
            .navigationTitle("Settings")
            .sheet(item: Binding(get: { share.map(IdentifiedShare.init) }, set: { share = $0?.share })) { item in
                CloudSharingView(share: item.share)
            }
        }
    }
}

private struct IdentifiedShare: Identifiable {
    let share: CKShare
    var id: String { share.recordID.recordName }
}

/// Apple's sharing sheet: add people by Apple Account and set read/write.
struct CloudSharingView: UIViewControllerRepresentable {
    let share: CKShare

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: FamilyService.container)
        controller.availablePermissions = [.allowReadWrite, .allowPrivate]
        return controller
    }

    func updateUIViewController(_ controller: UICloudSharingController, context: Context) {}
}

/// Rules and device health for one kid (PLAN.md §4.6, §4.7).
struct KidSettingsView: View {
    @Environment(AppModel.self) private var model
    let kid: Kid
    @State private var editing: Rule?

    var body: some View {
        let heartbeat = model.data.heartbeats[kid.id]
        Form {
            Section("Health") {
                let issues = model.healthIssues(for: kid)
                if issues.isEmpty {
                    Label("All good", systemImage: "checkmark.circle").foregroundStyle(.green)
                }
                ForEach(issues, id: \.self) { issue in
                    Label(issue.summary, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                LabeledContent("Last heartbeat", value: heartbeat.map { Format.relative($0.at) } ?? "never")
                LabeledContent("Last usage event", value: model.data.lastFireAt[kid.id].map(Format.relative) ?? "never")
                if let heartbeat {
                    LabeledContent("Screen Time access", value: heartbeat.authStatus)
                    LabeledContent("Schedules", value: "\(heartbeat.activeActivities.count) running / \(heartbeat.expectedActivities.count) expected")
                    LabeledContent("Waiting to upload", value: "\(heartbeat.backlogCount)")
                    LabeledContent("App version", value: heartbeat.appVersion)
                }
                Button("Ping now") { Task { await model.ping(kid) } }
            }
            Section("Rules") {
                ForEach(model.data.rules(for: kid.id)) { rule in
                    Button {
                        editing = rule
                    } label: {
                        HStack {
                            Text(rule.condition.summary)
                            Spacer()
                            if !rule.enabled { Text("Off").foregroundStyle(.secondary) }
                        }
                    }
                    .swipeActions { Button("Delete", role: .destructive) { Task { await model.delete(rule) } } }
                }
                Menu("Add rule") {
                    Button("Bedtime") {
                        editing = Rule(kidID: kid.id, condition: .quietHours(name: "Bedtime", startMinute: 21 * 60 + 30,
                                                                             endMinute: 7 * 60, weekdays: [], repeatEvery: 30))
                    }
                    Button("School hours") {
                        editing = Rule(kidID: kid.id, condition: .quietHours(name: "School", startMinute: 8 * 60,
                                                                             endMinute: 15 * 60, weekdays: [2, 3, 4, 5, 6],
                                                                             repeatEvery: 30))
                    }
                    Button("Daily phone total") {
                        editing = Rule(kidID: kid.id, condition: .dailyThreshold(itemID: nil, minutes: 180))
                    }
                    Button("Daily app limit") {
                        editing = Rule(kidID: kid.id, condition: .dailyThreshold(itemID: model.data.items(for: kid.id).values
                            .first { $0.kind == .app }?.id, minutes: 60))
                    }
                    Button("Long session") { editing = Rule(kidID: kid.id, condition: .longSession(minutes: 60)) }
                    Button("Untracked app use") { editing = Rule(kidID: kid.id, condition: .unexplainedUsage(minutes: 30)) }
                    Button("Phone offline") {
                        editing = Rule(kidID: kid.id, condition: .staleness(hours: 3, wakingStartMinute: 7 * 60,
                                                                            wakingEndMinute: 22 * 60))
                    }
                }
            }
        }
        .navigationTitle(kid.displayName)
        .sheet(item: $editing) { rule in
            RuleEditor(rule: rule, items: model.data.items(for: kid.id)) { saved in
                Task { await model.save(saved) }
            }
        }
    }
}

struct RuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var rule: Rule
    let items: [UUID: TrackedItem]
    let onSave: (Rule) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Toggle("Enabled", isOn: $rule.enabled)
                switch rule.condition {
                case let .quietHours(name, start, end, weekdays, repeatEvery):
                    TextField("Name", text: Binding(get: { name }, set: {
                        rule.condition = .quietHours(name: $0, startMinute: start, endMinute: end, weekdays: weekdays, repeatEvery: repeatEvery)
                    }))
                    minutePicker("Starts", start) {
                        rule.condition = .quietHours(name: name, startMinute: $0, endMinute: end, weekdays: weekdays, repeatEvery: repeatEvery)
                    }
                    minutePicker("Ends", end) {
                        rule.condition = .quietHours(name: name, startMinute: start, endMinute: $0, weekdays: weekdays, repeatEvery: repeatEvery)
                    }
                    Stepper("Remind every \(repeatEvery) min", value: Binding(get: { repeatEvery }, set: {
                        rule.condition = .quietHours(name: name, startMinute: start, endMinute: end, weekdays: weekdays, repeatEvery: $0)
                    }), in: 5...120, step: 5)
                    Section("Days (empty = every day)") {
                        ForEach(1...7, id: \.self) { weekday in
                            Toggle(Calendar.current.weekdaySymbols[weekday - 1], isOn: Binding(
                                get: { weekdays.contains(weekday) },
                                set: { on in
                                    var days = weekdays
                                    if on { days.insert(weekday) } else { days.remove(weekday) }
                                    rule.condition = .quietHours(name: name, startMinute: start, endMinute: end, weekdays: days, repeatEvery: repeatEvery)
                                }))
                        }
                    }
                case let .dailyThreshold(itemID, minutes):
                    Picker("What", selection: Binding(get: { itemID }, set: {
                        rule.condition = .dailyThreshold(itemID: $0, minutes: minutes)
                    })) {
                        Text("Whole phone").tag(UUID?.none)
                        ForEach(items.values.sorted { $0.ordinal < $1.ordinal }) { item in
                            ItemName(item: item, showIcon: false).tag(UUID?.some(item.id))
                        }
                    }
                    Stepper("After \(Format.minutes(minutes))", value: Binding(get: { minutes }, set: {
                        let snapped = itemID == nil ? $0 : LadderSpec.standard.snapItemThreshold($0)
                        rule.condition = .dailyThreshold(itemID: itemID, minutes: snapped)
                    }), in: 5...720, step: minutes < 60 ? 5 : 15)
                case let .longSession(minutes):
                    Stepper("Longer than \(Format.minutes(minutes))", value: Binding(get: { minutes }, set: {
                        rule.condition = .longSession(minutes: $0)
                    }), in: 15...300, step: 15)
                case let .unexplainedUsage(minutes):
                    Stepper("More than \(Format.minutes(minutes))", value: Binding(get: { minutes }, set: {
                        rule.condition = .unexplainedUsage(minutes: $0)
                    }), in: 10...240, step: 10)
                case let .staleness(hours, start, end):
                    Stepper("No report for \(hours) h", value: Binding(get: { hours }, set: {
                        rule.condition = .staleness(hours: $0, wakingStartMinute: start, wakingEndMinute: end)
                    }), in: 1...24)
                    minutePicker("Waking from", start) {
                        rule.condition = .staleness(hours: hours, wakingStartMinute: $0, wakingEndMinute: end)
                    }
                    minutePicker("Waking until", end) {
                        rule.condition = .staleness(hours: hours, wakingStartMinute: start, wakingEndMinute: $0)
                    }
                }
            }
            .navigationTitle(rule.condition.summary)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(rule)
                        dismiss()
                    }
                }
            }
        }
    }

    private func minutePicker(_ title: String, _ minute: Int, set: @escaping (Int) -> Void) -> some View {
        let start = Calendar.current.startOfDay(for: Date())
        return DatePicker(title, selection: Binding(
            get: { start.addingTimeInterval(Double(minute) * 60) },
            set: {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
                set(parts.hour! * 60 + parts.minute!)
            }), displayedComponents: .hourAndMinute)
    }
}
