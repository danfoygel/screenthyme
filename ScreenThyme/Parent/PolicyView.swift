import SwiftUI
import ThymeCore

/// ScreenThyme's replacement for Apple's Screen Time settings for one kid (PLAN.md §15): Downtime, App Limits,
/// Always Allowed, blocked apps and Content & Privacy. Edits a draft; Save asks whether it's for good or for some days
/// (PLAN.md §15.10), then sends it to the kid's phone.
struct PolicyView: View {
    @Environment(AppModel.self) private var model
    let kid: Kid
    @State private var draft: Policy?
    @State private var editingWindow: DowntimeWindow?
    @State private var editingLimit: AppLimit?
    @State private var editingGroup: ItemGroup?
    @State private var saving = false

    var body: some View {
        let stored = model.data.policy(for: kid.id)
        let policy = draft ?? stored
        let items = model.data.items(for: kid.id)
        Form {
            RebuildingNotice()
            Section {
                Toggle("Enforce on \(kid.displayName)'s phone", isOn: binding(policy, \.enabled))
            } footer: {
                Text("ScreenThyme blocks apps itself because it holds \(kid.displayName)'s usage data, which Apple's Screen Time then can't use. Don't set up Screen Time for \(kid.displayName) in Settings: it would take the data back.")
            }
            let reverts = stored.reverts(through: .distantFuture).filter { !$0.edits.isEmpty }
            if !reverts.isEmpty {
                Section {
                    ForEach(reverts, id: \.change.id) { step in
                        let name = PolicyHistoryRow.namer(groups: step.before.groups + step.after.groups, items: items)
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Changes back \(PolicyHistoryRow.end(step.change.until))", systemImage: "timer")
                            ForEach(Array(step.edits.enumerated()), id: \.offset) { _, edit in
                                Text(edit.describe(name: name).title).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Temporary changes")
                } footer: {
                    Text("Each changes back by itself at midnight, on \(kid.displayName)'s phone too. What's changed again before then stays.")
                }
            }
            Section("Downtime") {
                ForEach(policy.downtime) { window in
                    Button { editingWindow = window } label: {
                        LabeledContent {
                            Text(window.schedule())
                        } label: {
                            Text(window.name)
                            if !window.isWholePhone { Text(Self.names(window.items, items: items, groups: policy.groups)) }
                        }
                    }
                    .swipeActions { Button("Delete", role: .destructive) { update(policy) { $0.downtime.removeAll { $0.id == window.id } } } }
                }
                Button("Add Downtime") {
                    editingWindow = DowntimeWindow(name: "Bedtime", startMinute: 21 * 60 + 30, endMinute: 7 * 60)
                }
            }
            Section {
                let today = model.data.grants.values.filter { $0.kidID == kid.id && Calendar.current.isDateInToday($0.at) }
                ForEach(policy.limits) { limit in
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
                                    Text("More time today for \(Self.names(forApps, items: items, groups: []))")
                                }
                            }
                        }
                    }
                    .swipeActions { Button("Delete", role: .destructive) { update(policy) { $0.limits.removeAll { $0.id == limit.id } } } }
                }
                Button("Add limit") { editingLimit = AppLimit(name: "", items: [], minutes: 60) }
            } header: {
                Text("App Limits")
            } footer: {
                Text("Always Allowed apps, ScreenThyme and Phone don't count toward limits. Extra time is what a parent gave today, when \(kid.displayName) asked for more; time asked from one app is for that app only.")
            }
            Section {
                ForEach(policy.groups) { group in
                    Button { editingGroup = group } label: {
                        LabeledContent { Text("\(group.items.count)") } label: { GroupName(group: group) }
                    }
                    .swipeActions { Button("Delete", role: .destructive) { update(policy) { $0.removeGroup(group.id) } } }
                }
                Button("Add group") { editingGroup = ItemGroup(name: "") }
            } header: {
                Text("Groups")
            } footer: {
                Text("Your own categories of apps, websites and Apple's categories, for Downtime, limits, Always Allowed and Blocked. A change to a group changes everything that uses it.")
            }
            Section {
                NavigationLink {
                    SelectedItemsView(title: "Always Allowed", items: items,
                                      footer: "These work during Downtime and don't count toward limits. ScreenThyme and Phone are always allowed too.",
                                      groups: policy.groups, selection: binding(policy, \.alwaysAllowed))
                } label: {
                    LabeledContent("Always Allowed", value: "\(policy.alwaysAllowed.count)")
                }
                NavigationLink {
                    SelectedItemsView(title: "Blocked", items: items, footer: "These never open.",
                                      groups: policy.groups, selection: binding(policy, \.blocked))
                } label: {
                    LabeledContent("Blocked", value: "\(policy.blocked.count)")
                }
            } footer: {
                Text("Always Allowed apps work during Downtime and don't count toward limits. Blocked apps never open. ScreenThyme and Phone are always allowed.")
            }
            Section {
                NavigationLink("Content & Privacy") { RestrictionsView(restrictions: binding(policy, \.restrictions)) }
            }
            Section {
                NavigationLink { PolicyHistoryView(kid: kid) } label: {
                    Label("Change history", systemImage: "clock.arrow.circlepath")
                }
            }
        }
        // A draft started from a mirror being re-fetched would replace the kid's policy when saved.
        .disabled(model.editsBlocked)
        .navigationTitle("Screen Time")
        .bugButton()
        .toolbar {
            if let draft, draft != stored {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saving = true }
                }
                ToolbarItem(placement: .cancellationAction) { Button("Revert") { self.draft = nil } }
            }
        }
        .sheet(isPresented: $saving) {
            if let draft {
                let name = PolicyHistoryRow.namer(groups: draft.groups + stored.groups, items: items)
                SavePolicySheet(kidName: kid.displayName,
                                changes: PolicyEdit.between(stored, draft).map { $0.describe(name: name) }) { until in
                    Task {
                        await model.save(draft, until: until)
                        self.draft = nil
                    }
                }
            }
        }
        .sheet(item: $editingWindow) { window in
            DowntimeEditor(window: window, items: items, groups: policy.groups) { saved in
                update(policy) { policy in
                    if let index = policy.downtime.firstIndex(where: { $0.id == saved.id }) {
                        policy.downtime[index] = saved
                    } else {
                        policy.downtime.append(saved)
                    }
                }
            }
        }
        .sheet(item: $editingLimit) { limit in
            LimitEditor(limit: limit, items: items, groups: policy.groups) { saved in
                update(policy) { policy in
                    if let index = policy.limits.firstIndex(where: { $0.id == saved.id }) {
                        policy.limits[index] = saved
                    } else {
                        policy.limits.append(saved)
                    }
                }
            }
        }
        .sheet(item: $editingGroup) { group in
            GroupEditor(group: group, items: items, usedBy: Self.uses(of: group.id, in: policy)) { saved in
                update(policy) { policy in
                    if let index = policy.groups.firstIndex(where: { $0.id == saved.id }) {
                        policy.groups[index] = saved
                    } else {
                        policy.groups.append(saved)
                    }
                }
            }
        }
    }

    /// "Games, YouTube and 2 more": groups first, then items.
    static func names(_ ids: Set<UUID>, items: [UUID: TrackedItem], groups: [ItemGroup]) -> String {
        let names = groups.filter { ids.contains($0.id) }.map(\.name).sorted()
            + ids.compactMap { items[$0].map { AppCatalog.shared.name(of: $0, in: items) ?? $0.displayName } }.sorted()
        guard names.count > 2 else { return names.joined(separator: ", ") }
        return "\(names[0]), \(names[1]) and \(names.count - 2) more"
    }

    /// What uses group `id`: Downtime windows, limits, Always Allowed and Blocked.
    static func uses(of id: UUID, in policy: Policy) -> [String] {
        policy.downtime.filter { $0.items.contains(id) }.map { "Downtime \u{201C}\($0.name)\u{201D}" }
            + policy.limits.filter { !$0.allApps && $0.items.contains(id) }.map { "Limit \u{201C}\($0.name)\u{201D}" }
            + (policy.alwaysAllowed.contains(id) ? ["Always Allowed"] : [])
            + (policy.blocked.contains(id) ? ["Blocked"] : [])
    }

    private func update(_ policy: Policy, _ change: (inout Policy) -> Void) {
        var policy = policy
        change(&policy)
        draft = policy
    }

    private func binding<Value>(_ policy: Policy, _ keyPath: WritableKeyPath<Policy, Value>) -> Binding<Value> {
        Binding(get: { (draft ?? policy)[keyPath: keyPath] }, set: { value in update(policy) { $0[keyPath: keyPath] = value } })
    }
}

/// Asks on Save whether the changes are permanent or for some days, and lists them.
struct SavePolicySheet: View {
    @Environment(\.dismiss) private var dismiss
    let kidName: String
    let changes: [(title: String, details: [String])]
    /// The midnight the changes end, or nil for permanent ones.
    let onSave: (Date?) -> Void
    @State private var temporary = false
    @State private var days = 1

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Keep", selection: $temporary) {
                        Text("Permanent").tag(false)
                        Text("Temporary").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if temporary {
                        Stepper(days == 1 ? "Today only" : "For \(days) days, from today", value: $days, in: 1...30)
                    }
                } footer: {
                    Text(temporary ? "Changes back by itself \(PolicyHistoryRow.end(until)), on \(kidName)'s phone too. What's changed again before then stays."
                         : "Stays until someone changes it.")
                }
                Section("Changes") {
                    ForEach(Array(changes.enumerated()), id: \.offset) { _, line in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.title)
                            ForEach(line.details, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .navigationTitle("Save changes")
            .navigationBarTitleDisplayMode(.inline)
            .bugButton()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(temporary ? until : nil)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var until: Date { TemporaryChange.until(days: days, from: Date()) }
}

struct DowntimeEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var window: DowntimeWindow
    /// Blocks only `window.items`, not the whole phone.
    @State private var onlySome: Bool
    let items: [UUID: TrackedItem]
    let groups: [ItemGroup]
    let onSave: (DowntimeWindow) -> Void

    init(window: DowntimeWindow, items: [UUID: TrackedItem], groups: [ItemGroup], onSave: @escaping (DowntimeWindow) -> Void) {
        _window = State(initialValue: window)
        _onlySome = State(initialValue: !window.isWholePhone)
        self.items = items
        self.groups = groups
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $window.name)
                MinutePicker(title: "From", minute: $window.startMinute)
                MinutePicker(title: "Until", minute: $window.endMinute)
                Section {
                    Picker("Blocks", selection: $onlySome) {
                        Text("Whole phone").tag(false)
                        Text("Some apps").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if onlySome {
                        NavigationLink {
                            ItemSelectionView(title: "Downtime", items: items, groups: groups, selection: $window.items)
                        } label: {
                            LabeledContent("Included", value: "\(window.items.count)")
                        }
                        SelectionRows(ids: window.items, items: items, groups: groups)
                    }
                } header: {
                    Text("Blocks")
                } footer: {
                    Text(onlySome ? "Only these, so other apps keep working. Always Allowed apps work too."
                         : "Everything but Always Allowed, ScreenThyme and Phone.")
                }
                Section {
                    WeekdayToggles(weekdays: $window.weekdays)
                } header: {
                    Text("Days")
                } footer: {
                    Text("None selected means every day. A window past midnight belongs to the day it starts.")
                }
            }
            .navigationTitle("Downtime")
            .bugButton()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if !onlySome { window.items = [] }
                        onSave(window)
                        dismiss()
                    }
                    .disabled(window.name.isEmpty || window.startMinute == window.endMinute || onlySome && window.items.isEmpty)
                }
            }
        }
    }
}

struct LimitEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var limit: AppLimit
    let items: [UUID: TrackedItem]
    var groups: [ItemGroup] = []
    let onSave: (AppLimit) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $limit.name, prompt: Text(suggestedName))
                Toggle("On", isOn: $limit.enabled)
                Stepper("\(Format.minutes(limit.minutes)) a day", value: $limit.minutes, in: 5...720, step: 5)
                Section("Other days") {
                    ForEach(1...7, id: \.self) { weekday in
                        let custom = limit.weekdayMinutes[weekday]
                        Stepper(value: Binding(get: { custom ?? limit.minutes }, set: { limit.weekdayMinutes[weekday] = $0 }),
                                in: 5...720, step: 5) {
                            LabeledContent(Calendar.current.weekdaySymbols[weekday - 1],
                                           value: custom.map(Format.minutes) ?? "same")
                        }
                        .swipeActions { Button("Same") { limit.weekdayMinutes[weekday] = nil } }
                    }
                }
                Section {
                    Toggle("All apps and websites", isOn: $limit.allApps)
                    if !limit.allApps {
                        NavigationLink {
                            ItemSelectionView(title: "Limit", items: items, groups: groups, selection: $limit.items)
                        } label: {
                            LabeledContent("Included", value: "\(limit.items.count)")
                        }
                        SelectionRows(ids: limit.items, items: items, groups: groups)
                    }
                } header: {
                    Text("Apps, websites, categories and groups")
                } footer: {
                    if limit.allApps {
                        Text("Everything but Always Allowed, ScreenThyme and Phone. Checked every minute of use.")
                    } else if oneByOneCount > ShieldBudget.cap {
                        Text("An iPhone blocks at most \(ShieldBudget.cap) apps one by one, for limits, Downtime and Blocked together. Past that, ScreenThyme blocks the ones used most recently, and any other about a minute after it's opened. Categories and All apps have no such cap.")
                    }
                }
            }
            .navigationTitle("App Limit")
            .bugButton()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if limit.name.isEmpty { limit.name = suggestedName }
                        onSave(limit)
                        dismiss()
                    }
                    .disabled(!limit.allApps && limit.items.isEmpty)
                }
            }
        }
    }

    /// A scanned app goes by the app it's matched to; an unmatched one has no name, so it only counts.
    private var suggestedName: String {
        if limit.allApps { return "All apps" }
        let chosenGroups = groups.filter { limit.items.contains($0.id) }
        let chosenItems = limit.items.compactMap { items[$0] }
        let names = chosenGroups.map(\.name).sorted()
            + chosenItems.compactMap { AppCatalog.shared.name(of: $0, in: items) }.sorted()
        let count = chosenGroups.count + chosenItems.count
        guard let first = names.first ?? chosenItems.first?.displayName else { return "Limit" }
        return count > 1 ? "\(first) and \(count - 1) more" : first
    }

    /// Apps and websites the limit names, directly or through its groups: iOS shields them one by one.
    private var oneByOneCount: Int {
        let ids = limit.items.union(groups.filter { limit.items.contains($0.id) }.flatMap(\.items))
        return ids.filter { items[$0].map { $0.kind != .category } == true }.count
    }
}

/// The groups and items of a selection, groups first.
struct SelectionRows: View {
    let ids: Set<UUID>
    let items: [UUID: TrackedItem]
    let groups: [ItemGroup]

    var body: some View {
        ForEach(groups.filter { ids.contains($0.id) }.sorted { $0.name < $1.name }) { GroupName(group: $0) }
        ForEach(ids.compactMap { items[$0] }.sorted { $0.displayName < $1.displayName }) { ItemName(item: $0) }
    }
}

/// A group: a name and apps, websites and Apple's categories (PLAN.md §15.8).
struct GroupEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var group: ItemGroup
    let items: [UUID: TrackedItem]
    /// Downtime windows, limits and lists that use the group.
    let usedBy: [String]
    let onSave: (ItemGroup) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $group.name, prompt: Text("Games"))
                Section {
                    NavigationLink {
                        ItemSelectionView(title: group.name.isEmpty ? "Group" : group.name, items: items, selection: $group.items)
                    } label: {
                        LabeledContent("Included", value: "\(group.items.count)")
                    }
                    SelectionRows(ids: group.items, items: items, groups: [])
                } header: {
                    Text("Apps, websites and categories")
                } footer: {
                    Text(usedBy.isEmpty ? "Use the group in Downtime, limits, Always Allowed or Blocked."
                         : "Used by \(usedBy.joined(separator: ", ")).")
                }
            }
            .navigationTitle("Group")
            .bugButton()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        group.name = group.name.trimmingCharacters(in: .whitespaces)
                        onSave(group)
                        dismiss()
                    }
                    .disabled(group.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

/// Multi-select over the kid's categories, apps and websites, as found in Apple's data, and the parents' groups.
struct ItemSelectionView: View {
    let title: String
    let items: [UUID: TrackedItem]
    var groups: [ItemGroup] = []
    @Binding var selection: Set<UUID>
    @State private var search = ""

    var body: some View {
        // Only items with a token can be shielded: those from the app scan on the kid's phone (PLAN.md §15.3).
        // Scanned apps get a name to sort and search by once matched to Apple's data (§15.6).
        let catalog = AppCatalog.shared
        let named = items.values.filter { $0.tokenData != nil }.map { ($0, catalog.name(of: $0, in: items)) }
        List {
            if named.isEmpty {
                Text("On the kid's phone, open ScreenThyme and scan apps under Apps for Screen Time.")
                    .foregroundStyle(.secondary)
            }
            let shownGroups = groups.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            if !shownGroups.isEmpty {
                Section("Groups") {
                    ForEach(shownGroups) { group in
                        Button {
                            if selection.contains(group.id) { selection.remove(group.id) } else { selection.insert(group.id) }
                        } label: {
                            HStack {
                                GroupName(group: group)
                                Spacer()
                                Text("\(group.items.count)").foregroundStyle(.secondary)
                                if selection.contains(group.id) { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                        .tint(.primary)
                    }
                }
            }
            ForEach([ItemKind.category, .app, .domain], id: \.self) { kind in
                let group = named.filter { $0.0.kind == kind && $0.1 != nil
                    && (search.isEmpty || $0.1!.localizedCaseInsensitiveContains(search)) }
                    .sorted { $0.1!.localizedCaseInsensitiveCompare($1.1!) == .orderedAscending }
                if !group.isEmpty {
                    Section(kind.pluralTitle) {
                        ForEach(group, id: \.0.id) { row($0.0) }
                    }
                }
            }
            // Never used since the scan (or a category): only Apple's label knows the name.
            let unnamed = named.filter { $0.1 == nil }.map(\.0).sorted { $0.kind.rawValue < $1.kind.rawValue }
            if search.isEmpty, !unnamed.isEmpty {
                Section {
                    ForEach(unnamed) { row($0) }
                } header: {
                    Text("Not matched yet")
                } footer: {
                    Text("Apps get a name to search by the first time they're used for a minute after the scan.")
                }
            }
        }
        .searchable(text: $search)
        .navigationTitle(title)
        .bugButton()
    }

    private func row(_ item: TrackedItem) -> some View {
        Button {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        } label: {
            HStack {
                ItemName(item: item)
                Spacer()
                if selection.contains(item.id) { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
        .tint(.primary)
    }
}

/// Content & Privacy restrictions available to third-party apps.
struct RestrictionsView: View {
    @Binding var restrictions: Restrictions

    var body: some View {
        Form {
            Section("App Store") {
                Toggle("Block installing apps", isOn: $restrictions.denyAppInstallation)
                Toggle("Block deleting apps", isOn: $restrictions.denyAppRemoval)
                Toggle("Block in-app purchases", isOn: $restrictions.denyInAppPurchases)
                Toggle("Always require password", isOn: $restrictions.requirePasswordForPurchases)
                Picker("Apps up to", selection: $restrictions.maximumAppRating) {
                    Text("All").tag(Int?.none)
                    ForEach(Restrictions.appRatings, id: \.0) { Text($0.1).tag(Int?.some($0.0)) }
                }
            }
            Section("Media") {
                Toggle("Block explicit music, podcasts and books", isOn: $restrictions.denyExplicitContent)
                Picker("Movies up to", selection: $restrictions.maximumMovieRating) {
                    Text("All").tag(Int?.none)
                    ForEach(Restrictions.movieRatings, id: \.0) { Text($0.1).tag(Int?.some($0.0)) }
                }
                Picker("TV shows up to", selection: $restrictions.maximumTVShowRating) {
                    Text("All").tag(Int?.none)
                    ForEach(Restrictions.tvRatings, id: \.0) { Text($0.1).tag(Int?.some($0.0)) }
                }
                Toggle("Block sexual content in books", isOn: $restrictions.denyBookstoreErotica)
                Toggle("Block Apple Music", isOn: $restrictions.denyMusicService)
            }
            Section("Web") {
                Picker("Websites", selection: Binding(get: { WebMode(restrictions.webFilter) }, set: { mode in
                    restrictions.webFilter = mode.filter(keeping: restrictions.webFilter)
                })) {
                    ForEach(WebMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                switch restrictions.webFilter {
                case .unrestricted:
                    EmptyView()
                case let .limitAdult(allowed, blocked):
                    DomainListLink(title: "Always allow", domains: Binding(get: { allowed }, set: {
                        restrictions.webFilter = .limitAdult(allowed: $0, blocked: blocked)
                    }))
                    DomainListLink(title: "Never allow", domains: Binding(get: { blocked }, set: {
                        restrictions.webFilter = .limitAdult(allowed: allowed, blocked: $0)
                    }))
                case let .allowedOnly(allowed):
                    DomainListLink(title: "Allowed websites", domains: Binding(get: { allowed }, set: {
                        restrictions.webFilter = .allowedOnly($0)
                    }))
                }
                Toggle("Block Safari AutoFill", isOn: $restrictions.denySafariAutoFill)
            }
            Section("Other") {
                Toggle("Block Siri", isOn: $restrictions.denySiri)
                Toggle("Block multiplayer games", isOn: $restrictions.denyMultiplayerGaming)
                Toggle("Block adding Game Center friends", isOn: $restrictions.denyAddingFriends)
            }
            Section {
                Toggle("Lock accounts", isOn: $restrictions.lockAccounts)
                Toggle("Lock passcode", isOn: $restrictions.lockPasscode)
                Toggle("Lock cellular data per app", isOn: $restrictions.lockAppCellularData)
                Toggle("Lock cellular plan", isOn: $restrictions.lockCellularPlan)
                Toggle("Lock eSIM", isOn: $restrictions.lockESIM)
                Toggle("Require automatic date and time", isOn: $restrictions.requireAutomaticDateAndTime)
            } header: {
                Text("Changes")
            } footer: {
                Text("Automatic date and time keeps Downtime and limits from being dodged by changing the clock.")
            }
        }
        .navigationTitle("Content & Privacy")
        .bugButton()
    }

    enum WebMode: CaseIterable {
        case unrestricted, limitAdult, allowedOnly

        init(_ filter: WebFilter) {
            switch filter {
            case .unrestricted: self = .unrestricted
            case .limitAdult: self = .limitAdult
            case .allowedOnly: self = .allowedOnly
            }
        }

        var title: String { filter(keeping: .unrestricted).modeTitle }

        func filter(keeping old: WebFilter) -> WebFilter {
            switch (self, old) {
            case (.unrestricted, _): .unrestricted
            case (.limitAdult, .limitAdult): old
            case (.limitAdult, _): .limitAdult(allowed: [], blocked: [])
            case (.allowedOnly, .allowedOnly): old
            case (.allowedOnly, _): .allowedOnly([])
            }
        }
    }
}

struct DomainListLink: View {
    let title: String
    @Binding var domains: [String]

    var body: some View {
        NavigationLink {
            DomainListView(title: title, domains: $domains)
        } label: {
            LabeledContent(title, value: "\(domains.count)")
        }
    }
}

struct DomainListView: View {
    let title: String
    @Binding var domains: [String]
    @State private var newDomain = ""

    var body: some View {
        List {
            ForEach(domains, id: \.self) { Text($0) }
                .onDelete { domains.remove(atOffsets: $0) }
            HStack {
                TextField("example.com", text: $newDomain)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                Button("Add") {
                    domains.append(newDomain.trimmingCharacters(in: .whitespaces).lowercased())
                    newDomain = ""
                }
                .disabled(newDomain.isEmpty)
            }
        }
        .navigationTitle(title)
        .bugButton()
    }
}

struct MinutePicker: View {
    let title: String
    @Binding var minute: Int

    var body: some View {
        let start = Calendar.current.startOfDay(for: Date())
        DatePicker(title, selection: Binding(
            get: { start.addingTimeInterval(Double(minute) * 60) },
            set: {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
                minute = parts.hour! * 60 + parts.minute!
            }), displayedComponents: .hourAndMinute)
    }
}

struct WeekdayToggles: View {
    @Binding var weekdays: Set<Int>

    var body: some View {
        ForEach(1...7, id: \.self) { weekday in
            Toggle(Calendar.current.weekdaySymbols[weekday - 1], isOn: Binding(
                get: { weekdays.contains(weekday) },
                set: { if $0 { weekdays.insert(weekday) } else { weekdays.remove(weekday) } }))
        }
    }
}

extension ItemKind {
    var pluralTitle: String {
        switch self {
        case .app: "Apps"
        case .domain: "Websites"
        case .category: "Categories"
        }
    }
}
