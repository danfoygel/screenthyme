import SwiftUI
import ThymeCore

/// The top of a kid's policy screen (PLAN.md §15.15): the ruleset in effect today, how it came to be, a switch for some
/// days, and the rulesets themselves.
struct RuleSetInEffectSection: View {
    let kid: Kid
    let policy: Policy
    /// The draft has unsaved changes: a switch saves at once, and a draft saved after it would undo it.
    let dirty: Bool
    @Binding var editing: Policy
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
            NavigationLink { RuleSetsView(kidName: kid.displayName, policy: $editing) } label: {
                LabeledContent("Rulesets", value: "\(editing.ruleSets.count)")
            }
        } header: {
            Text("Ruleset")
        } footer: {
            Text("Downtime, App Limits and Blocked apps belong to a ruleset; one is in effect each day, by its weekdays or chosen for some days. Everything else applies in every ruleset." + (dirty ? " Save or revert your changes to switch." : ""))
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
            .bugButton()
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

/// A kid's rulesets: their names and weekdays. Edits the policy screen's draft, saved with it.
struct RuleSetsView: View {
    let kidName: String
    @Binding var policy: Policy
    @State private var editing: PolicyRuleSet?
    @State private var adding = false

    var body: some View {
        List {
            Section {
                ForEach(policy.ruleSets) { set in
                    Button { editing = set } label: {
                        LabeledContent {
                            Text(set.days())
                        } label: {
                            Text(set.name).foregroundStyle(.primary)
                            Text(Self.summary(set))
                        }
                    }
                    .swipeActions {
                        if policy.ruleSets.count > 1 {
                            Button("Delete", role: .destructive) { policy.removeRuleSet(set.id) }
                        }
                    }
                }
                Button("Add ruleset") { adding = true }
            } footer: {
                let free = policy.unscheduledWeekdays
                Text("Each weekday has one ruleset; a ruleset with no days is in effect only when you switch to it."
                     + (free.isEmpty || policy.ruleSets.isEmpty ? ""
                        : " \(PolicyRuleSet.days(free)) \(free.count == 1 ? "has" : "have") none, so \(free.count == 1 ? "it gets" : "they get") \u{201C}\(policy.ruleSets[0].name)\u{201D}."))
            }
        }
        .navigationTitle("Rulesets")
        .bugButton()
        .sheet(item: $editing) { set in
            RuleSetEditor(ruleSet: set, isNew: false, policy: policy) { policy.save($0) }
        }
        .sheet(isPresented: $adding) {
            RuleSetEditor(ruleSet: PolicyRuleSet(name: ""), isNew: true, policy: policy) { policy.save($0) }
        }
    }

    /// "1 Downtime · 2 limits · 3 blocked".
    static func summary(_ set: PolicyRuleSet) -> String {
        let parts = [(set.downtime.count, "Downtime", "Downtime"), (set.limits.count, "limit", "limits"),
                     (set.blocked.count, "blocked", "blocked")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.0 == 1 ? $0.1 : $0.2)" }
        return parts.isEmpty ? "No rules" : parts.joined(separator: " · ")
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
            .bugButton()
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
