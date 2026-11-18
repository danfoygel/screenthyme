import SwiftUI
import ThymeCore

/// Which of a kid's scanned apps, websites or categories have been matched to Apple's usage data, and to what (PLAN.md §15.6).
/// Each row shows Apple's own label for the scanned token above the bundle ID or domain it was matched to, so a wrong
/// match stands out.
struct TokenMatchesView: View {
    @Environment(AppModel.self) private var model
    let kid: Kid
    let kind: ItemKind

    var body: some View {
        let items = model.data.items(for: kid.id)
        let scanned = Self.scanned(kind, in: items)
        let matched = scanned.compactMap { item in item.match.flatMap { items[$0] }.map { (item, $0) } }
            .sorted { name($0.1).lowercased() < name($1.1).lowercased() }
        let unmatched = scanned.filter { $0.match == nil || items[$0.match!] == nil }
        List {
            Section {
                if matched.isEmpty {
                    Text("None yet").foregroundStyle(.secondary)
                }
                ForEach(matched, id: \.0.id) { scannedItem, match in
                    VStack(alignment: .leading, spacing: 4) {
                        ItemName(item: scannedItem)
                        // A category's identifier is its name.
                        Text(match.kind == .category ? name(match) : "\(name(match)) · \(match.identifier)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Matched · \(matched.count)")
            } footer: {
                Text("Above: what \(kid.displayName)'s phone calls the \(noun). Below: the \(noun) in Apple's usage data it was matched to.")
            }
            Section {
                ForEach(unmatched) { item in
                    ItemName(item: item)
                }
            } header: {
                Text("Not matched yet · \(unmatched.count)")
            } footer: {
                Text("Matched by screenshot on \(kid.displayName)'s phone (Apps for Screen Time → Match apps by screenshot), once it has been used.")
            }
        }
        .navigationTitle(Self.title(kind))
    }

    static func title(_ kind: ItemKind) -> String {
        switch kind {
        case .app: "App matches"
        case .domain: "Website matches"
        case .category: "Category matches"
        }
    }

    private var noun: String {
        switch kind {
        case .app: "app"
        case .domain: "website"
        case .category: "category"
        }
    }

    /// Scanned apps, websites or categories still in the scan (they have a token), in the order the scan found them.
    static func scanned(_ kind: ItemKind, in items: [UUID: TrackedItem]) -> [TrackedItem] {
        items.values.filter { $0.kind == kind && $0.isScanned && $0.tokenData != nil }
            .sorted { ($0.firstSeen, $0.identifier) < ($1.firstSeen, $1.identifier) }
    }

    private func name(_ item: TrackedItem) -> String {
        item.kind == .app ? AppCatalog.shared.entries[item.identifier]?.name ?? item.displayName : item.displayName
    }
}
