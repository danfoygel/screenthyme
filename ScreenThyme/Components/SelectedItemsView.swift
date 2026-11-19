import SwiftUI
import ThymeCore

/// An Always Allowed or Blocked list, read-only: categories, apps and websites, by name. With a `selection` (on parents'
/// phones), Edit opens the full list to choose from.
struct SelectedItemsView: View {
    let title: String
    var ids: Set<UUID> = []
    let items: [UUID: TrackedItem]
    let footer: String
    /// The parents' groups, which a selection may name (parents' phones only).
    var groups: [ItemGroup] = []
    var selection: Binding<Set<UUID>>?
    @State private var editing = false

    var body: some View {
        let ids = selection?.wrappedValue ?? ids
        let catalog = AppCatalog.shared
        let listed = ids.compactMap { items[$0] }.map { ($0, catalog.name(of: $0, in: items) ?? "") }
        let chosenGroups = groups.filter { ids.contains($0.id) }.sorted { $0.name < $1.name }
        List {
            if !chosenGroups.isEmpty {
                Section("Groups") {
                    ForEach(chosenGroups) { GroupName(group: $0) }
                }
            }
            ForEach([ItemKind.category, .app, .domain], id: \.self) { kind in
                let group = listed.filter { $0.0.kind == kind }
                    .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
                if !group.isEmpty {
                    Section(kind.pluralTitle) {
                        ForEach(group, id: \.0.id) { item in ItemDetailsLink(item: item.0) { ItemName(item: item.0) } }
                    }
                }
            }
            // Removed from this phone's items since the parent chose it.
            let missing = ids.count - listed.count - chosenGroups.count
            Section {
                if ids.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                } else if missing > 0 {
                    Text(missing == 1 ? "1 app this phone doesn't know" : "\(missing) apps this phone doesn't know")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text(footer)
            }
        }
        .navigationTitle(title)
        .bugButton()
        .toolbar {
            if selection != nil { Button("Edit") { editing = true } }
        }
        .navigationDestination(isPresented: $editing) {
            if let selection { ItemSelectionView(title: title, items: items, groups: groups, selection: selection) }
        }
    }
}
