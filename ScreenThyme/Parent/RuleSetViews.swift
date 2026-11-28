import SwiftUI
import ThymeCore

/// The top of a kid's policy screen (PLAN.md §15.15): the ruleset in effect today, how it came to be, and a switch for
/// some days.
struct RuleSetInEffectSection: View {
    let policy: Policy
    /// The draft has unsaved changes: a switch saves at once, and a draft saved after it would undo it.
    let dirty: Bool
    @Binding var choosing: Bool

    var body: some View {
        let now = Date()
        Section {
            if let set = policy.ruleSet(on: now) {
                let choice = policy.choice(on: now)
                VStack(alignment: .leading, spacing: 4) {
                    Text("In effect today").font(.caption).foregroundStyle(.secondary)
                    Label(set.name, systemImage: choice == nil ? "calendar" : "hand.point.up.left.fill")
                        .font(.title2.bold())
                        .foregroundStyle(choice == nil ? Color.accentColor : .orange)
                    Text(choice.map { "Chosen by \($0.by) · \($0.span())" } ?? "Its days: \(set.days())")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            Button("Switch ruleset…") { choosing = true }
                .disabled(dirty)
        } header: {
            Text("Ruleset")
        } footer: {
            Text("One ruleset is in effect each day, by its weekdays or chosen for some days." + (dirty ? " Save or revert your changes to switch." : ""))
        }
    }
}

/// Chooses a ruleset for today only or some days, or goes back to each weekday's own.
struct ChooseRuleSetSheet: View {
    @Environment(\.dismiss) private var dismiss
    let kidName: String
    let policy: Policy
    /// The ruleset, or nil for each weekday's own, and for how many days counting today.
    let onChoose: (UUID?, Int) -> Void
    @State private var selection: UUID?
    @State private var days = 1

    init(kidName: String, policy: Policy, onChoose: @escaping (UUID?, Int) -> Void) {
        self.kidName = kidName
        self.policy = policy
        self.onChoose = onChoose
        // Another ruleset than today's: switching is for a change.
        let today = policy.ruleSet(on: Date())?.id
        _selection = State(initialValue: policy.ruleSets.first { $0.id != today && $0.weekdays.isEmpty }?.id
                           ?? policy.ruleSets.first { $0.id != today }?.id)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Ruleset") {
                    ForEach(policy.ruleSets) { set in
                        Button { selection = set.id } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(set.name).foregroundStyle(.primary)
                                    Text(set.days()).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selection == set.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                    }
                }
                Section {
                    Stepper(days == 1 ? "Today only" : "For \(days) days, from today", value: $days, in: 1...30)
                } footer: {
                    Text("Back to each day's own ruleset \(PolicyHistoryRow.end(until)), on \(kidName)'s phone too.")
                }
                if policy.choice(on: Date()) != nil {
                    Section {
                        Button("Back to each day's own ruleset now") {
                            onChoose(nil, 1)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Switch ruleset")
            .navigationBarTitleDisplayMode(.inline)
            .bugButton(help: .switchRuleSet)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Switch") {
                        onChoose(selection, days)
                        dismiss()
                    }
                    .disabled(selection == nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var until: Date { TemporaryChange.until(days: days, from: Date()) }
}

/// One ruleset's own rules (PLAN.md §15.15): its name and days, Downtime, App Limits, Blocked, limit warnings and breaks.
/// Edits the Screen Time screen's draft, saved from either screen.
struct RuleSetView: View {
    @Environment(AppModel.self) private var model
    let kid: Kid
    let ruleSetID: UUID
    @Binding var draft: Policy?
    @State private var editingWindow: DowntimeWindow?
    @State private var editingLimit: AppLimit?
    @State private var editingRuleSet = false

    var body: some View {
        let stored = model.data.policy(for: kid.id).withDefaultRuleSets()
        let policy = draft ?? stored
        let items = model.data.items(for: kid.id)
        let rules = policy.ruleSet(ruleSetID)
        Form {
            if let rules {
                sections(rules, policy: policy, stored: stored, items: items)
            } else {
                // Reverted (a new one) or deleted elsewhere.
                Text("This ruleset is gone.").foregroundStyle(.secondary)
            }
        }
        // A draft started from a mirror being re-fetched would replace the kid's policy when saved.
        .disabled(model.editsBlocked)
        .navigationTitle(rules?.name ?? "Ruleset")
        .bugButton(help: .ruleSet)
        .modifier(PolicyDraftToolbar(kid: kid, stored: stored, draft: $draft))
        .sheet(isPresented: $editingRuleSet) {
            if let rules {
                RuleSetEditor(ruleSet: rules, isNew: false, policy: policy) { saved in
                    update(draft ?? policy) { $0.save(saved) }
                }
            }
        }
        .sheet(item: $editingWindow) { window in
            DowntimeEditor(window: window, items: items, groups: policy.groups) { saved in
                update(draft ?? policy) { policy in
                    policy.editRuleSet(ruleSetID) { set in
                        if let index = set.downtime.firstIndex(where: { $0.id == saved.id }) {
                            set.downtime[index] = saved
                        } else {
                            set.downtime.append(saved)
                        }
                    }
                }
            }
        }
        .sheet(item: $editingLimit) { limit in
            LimitEditor(limit: limit, items: items, groups: policy.groups) { saved in
                update(draft ?? policy) { policy in
                    policy.editRuleSet(ruleSetID) { set in
                        if let index = set.limits.firstIndex(where: { $0.id == saved.id }) {
                            set.limits[index] = saved
                        } else {
                            set.limits.append(saved)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sections(_ rules: PolicyRuleSet, policy: Policy, stored: Policy, items: [UUID: TrackedItem]) -> some View {
        Section {
            Button { editingRuleSet = true } label: {
                LabeledContent("Name and days", value: rules.days())
            }
        } footer: {
            Text((rules.id == stored.ruleSet(on: Date())?.id ? "In effect today. " : "")
                 + "Downtime, App Limits, Blocked, limit warnings and breaks here are \(rules.name)'s own. Everything else on the Screen Time screen is the same in every ruleset.")
        }
        Section("Downtime") {
            ForEach(rules.downtime) { window in
                Button { editingWindow = window } label: {
                    LabeledContent {
                        Text(window.schedule())
                    } label: {
                        Text(window.name)
                        if !window.isWholePhone { Text(PolicyView.names(window.items, items: items, groups: policy.groups)) }
                    }
                }
                .swipeActions {
                    Button("Delete", role: .destructive) {
                        update(policy) { $0.editRuleSet(rules.id) { $0.downtime.removeAll { $0.id == window.id } } }
                    }
                }
            }
            Button("Add Downtime") {
                editingWindow = DowntimeWindow(name: "Bedtime", startMinute: 21 * 60 + 30, endMinute: 7 * 60)
            }
        }
        Section {
            let today = model.data.grants.values.filter { $0.kidID == kid.id && Calendar.current.isDateInToday($0.at) }
            ForEach(rules.limits) { limit in
                Button { editingLimit = limit } label: {
                    LabeledContent {
                        Text(limit.enabled ? Format.minutes(limit.minutes) + " a day" : "Off")
                    } label: {
                        Text(limit.name)
                        if limit.enabled {
                            switch EnforcementPlanner.extraMinutes(for: limit.id, grants: today) {
                            case 0?: EmptyView()
                            case let extra?: Text("\(Format.minutes(extra)) extra today")
                            case nil: Text("No limit for the rest of today")
                            }
                            let forApps = Set(today.filter { $0.approved && $0.reason == .limit(limit.id) }.compactMap(\.itemID))
                            if !forApps.isEmpty {
                                Text("More time today for \(PolicyView.names(forApps, items: items, groups: []))")
                            }
                        }
                    }
                }
                .swipeActions {
                    Button("Delete", role: .destructive) {
                        update(policy) { $0.editRuleSet(rules.id) { $0.limits.removeAll { $0.id == limit.id } } }
                    }
                }
            }
            Button("Add limit") { editingLimit = AppLimit(name: "", items: [], minutes: 60) }
        } header: {
            Text("App Limits")
        } footer: {
            Text("Always Allowed apps, ScreenThyme and Phone don't count toward limits. Extra time is what a parent gave today, when \(kid.displayName) asked for more; time asked from one app is for that app only.")
        }
        Section {
            NavigationLink {
                SelectedItemsView(title: "Blocked", items: items, footer: "These never open while \u{201C}\(rules.name)\u{201D} is in effect.",
                                  groups: policy.groups, selection: Binding(get: { rules.blocked }, set: { blocked in
                                      update(draft ?? policy) { $0.editRuleSet(rules.id) { $0.blocked = blocked } }
                                  }))
            } label: {
                LabeledContent("Blocked", value: "\(rules.blocked.count)")
            }
        } header: {
            Text("Blocked")
        } footer: {
            Text("Blocked apps never open. Always Allowed apps, on the Screen Time screen, are allowed in every ruleset.")
        }
        Section {
            // By position, checked: a swipe's delete can redraw a row whose index is gone.
            ForEach(Array(rules.limitWarningPercents.enumerated()), id: \.offset) { index, percent in
                Stepper {
                    Text("When \(percent)% is used")
                } onIncrement: {
                    stepWarning(rules, policy, index, up: true)
                } onDecrement: {
                    stepWarning(rules, policy, index, up: false)
                }
                .swipeActions {
                    Button("Delete", role: .destructive) {
                        update(policy) { policy in
                            policy.editRuleSet(rules.id) {
                                if $0.limitWarningPercents.indices.contains(index) { $0.limitWarningPercents.remove(at: index) }
                            }
                        }
                    }
                }
            }
            if let next = rules.nextLimitWarning {
                Button("Add a warning") { update(policy) { $0.editRuleSet(rules.id) { $0.limitWarningPercents.append(next) } } }
            }
        } header: {
            Text("Limit warnings")
        } footer: {
            Text("A notification on \(kid.displayName)'s phone once that much of a limit's time is used today, for each limit in \(rules.name). Each comes once a day; more time starts them over.")
        }
        Section {
            let breaks = Binding(get: { rules.breaks },
                                 set: { rule in update(draft ?? policy) { $0.editRuleSet(rules.id) { $0.breaks = rule } } })
            Toggle("Take breaks", isOn: breaks.enabled)
            if rules.breaks.enabled {
                MinutesStepper("After \(Format.minutes(rules.breaks.useMinutes)) of use", minutes: breaks.useMinutes,
                               range: 5...240)
                MinutesStepper("A break of \(Format.minutes(rules.breaks.breakMinutes))", minutes: breaks.breakMinutes,
                               range: 5...120)
            }
        } header: {
            Text("Breaks")
        } footer: {
            Text("After that much use with no rest as long as the break, everything but Always Allowed apps is blocked for the break. A shorter pause doesn't start the count over. Always Allowed apps, ScreenThyme and Phone don't count. \(kid.displayName) can ask for more time or take one more minute, as in Downtime.")
        }
    }

    /// "1 Downtime · 2 limits · 3 blocked · 2 warnings · breaks".
    static func summary(_ set: PolicyRuleSet) -> String {
        let parts = [(set.downtime.count, "Downtime", "Downtime"), (set.limits.count, "limit", "limits"),
                     (set.blocked.count, "blocked", "blocked"), (set.limitWarningPercents.count, "warning", "warnings")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.0 == 1 ? $0.1 : $0.2)" } + (set.breaks.enabled ? ["breaks"] : [])
        return parts.isEmpty ? "No rules" : parts.joined(separator: " · ")
    }

    private func stepWarning(_ rules: PolicyRuleSet, _ policy: Policy, _ index: Int, up: Bool) {
        guard let percent = rules.steppingLimitWarning(index, up: up) else { return }
        update(policy) { $0.editRuleSet(rules.id) { $0.limitWarningPercents[index] = percent } }
    }

    private func update(_ policy: Policy, _ change: (inout Policy) -> Void) {
        var policy = policy
        change(&policy)
        draft = policy
    }
}

/// A ruleset's name and weekdays; a new one starts empty or as a copy of another's rules.
struct RuleSetEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var ruleSet: PolicyRuleSet
    @State private var copyOf: UUID?
    let isNew: Bool
    let policy: Policy
    let onSave: (PolicyRuleSet) -> Void

    init(ruleSet: PolicyRuleSet, isNew: Bool, policy: Policy, onSave: @escaping (PolicyRuleSet) -> Void) {
        _ruleSet = State(initialValue: ruleSet)
        _copyOf = State(initialValue: isNew ? policy.ruleSet(on: Date())?.id : nil)
        self.isNew = isNew
        self.policy = policy
        self.onSave = onSave
    }

    var body: some View {
        let calendar = Calendar.current
        NavigationStack {
            Form {
                TextField("Name", text: $ruleSet.name)
                if isNew {
                    Picker("Start from", selection: $copyOf) {
                        Text("No rules").tag(UUID?.none)
                        ForEach(policy.ruleSets) { Text("A copy of \($0.name)").tag(Optional($0.id)) }
                    }
                }
                Section {
                    // Monday first, as a week reads.
                    ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { weekday in
                        let other = policy.ruleSets.first { $0.id != ruleSet.id && $0.weekdays.contains(weekday) }
                        Toggle(isOn: Binding(get: { ruleSet.weekdays.contains(weekday) }, set: { on in
                            if on { ruleSet.weekdays.insert(weekday) } else { ruleSet.weekdays.remove(weekday) }
                        })) {
                            Text(calendar.weekdaySymbols[weekday - 1])
                            if let other { Text(ruleSet.weekdays.contains(weekday) ? "Moves from \(other.name)" : other.name) }
                        }
                    }
                } header: {
                    Text("In effect on")
                } footer: {
                    Text("A day taken from another ruleset leaves it. With no days, it's in effect only when you switch to it.")
                }
            }
            .navigationTitle(isNew ? "New ruleset" : ruleSet.name)
            .navigationBarTitleDisplayMode(.inline)
            .bugButton(help: .ruleSetEditor(isNew: isNew))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        let name = ruleSet.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        var saved = ruleSet
                        if isNew, let source = copyOf.flatMap(policy.ruleSet) {
                            saved = source.copy(id: ruleSet.id, name: name, weekdays: ruleSet.weekdays)
                        }
                        saved.name = name
                        onSave(saved)
                        dismiss()
                    }
                    .disabled(ruleSet.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
