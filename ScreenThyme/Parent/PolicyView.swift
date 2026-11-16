import SwiftUI
import ThymeCore

/// ScreenThyme's replacement for Apple's Screen Time settings for one kid (PLAN.md §15): Downtime, App Limits,
/// Always Allowed, blocked apps and Content & Privacy. Edits a draft; Save sends it to the kid's phone.
struct PolicyView: View {
    @Environment(AppModel.self) private var model
    let kid: Kid
    @State private var draft: Policy?
    @State private var editingWindow: DowntimeWindow?
    @State private var editingLimit: AppLimit?

    var body: some View {
        let stored = model.data.policy(for: kid.id)
        let policy = draft ?? stored
        let items = model.data.items(for: kid.id)
        Form {
            Section {
                Toggle("Enforce on \(kid.displayName)'s phone", isOn: binding(policy, \.enabled))
            } footer: {
                Text("ScreenThyme blocks apps itself because it holds \(kid.displayName)'s usage data, which Apple's Screen Time then can't use. Don't set up Screen Time for \(kid.displayName) in Settings: it would take the data back.")
            }
            Section("Downtime") {
                ForEach(policy.downtime) { window in
                    Button { editingWindow = window } label: {
                        LabeledContent(window.name, value: Self.describe(window))
                    }
                    .swipeActions { Button("Delete", role: .destructive) { update(policy) { $0.downtime.removeAll { $0.id == window.id } } } }
                }
                Button("Add Downtime") {
                    editingWindow = DowntimeWindow(name: "Bedtime", startMinute: 21 * 60 + 30, endMinute: 7 * 60)
                }
            }
            Section("App Limits") {
                ForEach(policy.limits) { limit in
                    Button { editingLimit = limit } label: {
                        LabeledContent(limit.name, value: limit.enabled ? Format.minutes(limit.minutes) + " a day" : "Off")
                    }
                    .swipeActions { Button("Delete", role: .destructive) { update(policy) { $0.limits.removeAll { $0.id == limit.id } } } }
                }
                Button("Add limit") { editingLimit = AppLimit(name: "", items: [], minutes: 60) }
            }
            Section {
                NavigationLink {
                    ItemSelectionView(title: "Always Allowed", items: items, selection: binding(policy, \.alwaysAllowed))
                } label: {
                    LabeledContent("Always Allowed", value: "\(policy.alwaysAllowed.count)")
                }
                NavigationLink {
                    ItemSelectionView(title: "Blocked", items: items, selection: binding(policy, \.blocked))
                } label: {
                    LabeledContent("Blocked", value: "\(policy.blocked.count)")
                }
            } footer: {
                Text("Always Allowed apps work during Downtime and don't count toward limits. Blocked apps never open. ScreenThyme and Phone are always allowed.")
            }
            Section {
                NavigationLink("Content & Privacy") { RestrictionsView(restrictions: binding(policy, \.restrictions)) }
            }
        }
        .navigationTitle("Screen Time")
        .toolbar {
            if let draft, draft != stored {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await model.save(draft)
                            self.draft = nil
                        }
                    }
                }
                ToolbarItem(placement: .cancellationAction) { Button("Revert") { self.draft = nil } }
            }
        }
        .sheet(item: $editingWindow) { window in
            DowntimeEditor(window: window) { saved in
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
            LimitEditor(limit: limit, items: items) { saved in
                update(policy) { policy in
                    if let index = policy.limits.firstIndex(where: { $0.id == saved.id }) {
                        policy.limits[index] = saved
                    } else {
                        policy.limits.append(saved)
                    }
                }
            }
        }
    }

    private func update(_ policy: Policy, _ change: (inout Policy) -> Void) {
        var policy = policy
        change(&policy)
        draft = policy
    }

    private func binding<Value>(_ policy: Policy, _ keyPath: WritableKeyPath<Policy, Value>) -> Binding<Value> {
        Binding(get: { (draft ?? policy)[keyPath: keyPath] }, set: { value in update(policy) { $0[keyPath: keyPath] = value } })
    }

    static func describe(_ window: DowntimeWindow) -> String {
        let days = window.weekdays.isEmpty || window.weekdays.count == 7 ? "every day"
            : window.weekdays.sorted().map { Calendar.current.shortWeekdaySymbols[$0 - 1] }.joined(separator: " ")
        return "\(RuleCondition.clock(window.startMinute))–\(RuleCondition.clock(window.endMinute)), \(days)"
    }
}

struct DowntimeEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var window: DowntimeWindow
    let onSave: (DowntimeWindow) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $window.name)
                MinutePicker(title: "From", minute: $window.startMinute)
                MinutePicker(title: "Until", minute: $window.endMinute)
                Section {
                    WeekdayToggles(weekdays: $window.weekdays)
                } header: {
                    Text("Days")
                } footer: {
                    Text("None selected means every day. A window past midnight belongs to the day it starts.")
                }
            }
            .navigationTitle("Downtime")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(window)
                        dismiss()
                    }
                    .disabled(window.name.isEmpty || window.startMinute == window.endMinute)
                }
            }
        }
    }
}

struct LimitEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var limit: AppLimit
    let items: [UUID: TrackedItem]
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
                Section("Apps, websites and categories") {
                    NavigationLink {
                        ItemSelectionView(title: "Limit", items: items, selection: $limit.items)
                    } label: {
                        LabeledContent("Included", value: "\(limit.items.count)")
                    }
                    ForEach(limit.items.compactMap { items[$0] }.sorted { $0.displayName < $1.displayName }) { item in
                        ItemName(item: item)
                    }
                }
            }
            .navigationTitle("App Limit")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if limit.name.isEmpty { limit.name = suggestedName }
                        onSave(limit)
                        dismiss()
                    }
                    .disabled(limit.items.isEmpty)
                }
            }
        }
    }

    private var suggestedName: String {
        let names = limit.items.compactMap { items[$0]?.displayName }.sorted()
        return names.count > 1 ? "\(names[0]) and \(names.count - 1) more" : names.first ?? "Limit"
    }
}

/// Multi-select over the kid's categories, apps and websites, as found in Apple's data.
struct ItemSelectionView: View {
    let title: String
    let items: [UUID: TrackedItem]
    @Binding var selection: Set<UUID>
    @State private var search = ""

    var body: some View {
        // Only items with a token can be shielded: those from the app scan on the kid's phone (PLAN.md §15.3).
        // Scanned apps get a name to sort and search by once matched to Apple's data (§15.5).
        let catalog = AppCatalog.shared
        let named = items.values.filter { $0.tokenData != nil }.map { ($0, catalog.name(of: $0, in: items)) }
        List {
            if named.isEmpty {
                Text("On the kid's phone, open ScreenThyme and scan apps under Apps for Screen Time.")
                    .foregroundStyle(.secondary)
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
                    Text("4+").tag(Int?.some(100))
                    Text("9+").tag(Int?.some(200))
                    Text("12+").tag(Int?.some(300))
                    Text("17+").tag(Int?.some(600))
                }
            }
            Section("Media") {
                Toggle("Block explicit music, podcasts and books", isOn: $restrictions.denyExplicitContent)
                Picker("Movies up to", selection: $restrictions.maximumMovieRating) {
                    Text("All").tag(Int?.none)
                    Text("G").tag(Int?.some(100))
                    Text("PG").tag(Int?.some(200))
                    Text("PG-13").tag(Int?.some(300))
                    Text("R").tag(Int?.some(400))
                }
                Picker("TV shows up to", selection: $restrictions.maximumTVShowRating) {
                    Text("All").tag(Int?.none)
                    Text("TV-Y").tag(Int?.some(100))
                    Text("TV-Y7").tag(Int?.some(200))
                    Text("TV-G").tag(Int?.some(300))
                    Text("TV-PG").tag(Int?.some(400))
                    Text("TV-14").tag(Int?.some(500))
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

        var title: String {
            switch self {
            case .unrestricted: "Unrestricted"
            case .limitAdult: "Limit adult websites"
            case .allowedOnly: "Allowed websites only"
            }
        }

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
