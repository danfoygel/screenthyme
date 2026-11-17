import SwiftUI
import ThymeCore

/// Which of a kid's scanned apps have been matched to Apple's usage data, and to what (PLAN.md §15.6). Each row shows
/// Apple's own label for the scanned token above the bundle ID it was matched to, so a wrong match stands out.
struct TokenMatchesView: View {
    @Environment(AppModel.self) private var model
    let kid: Kid

    var body: some View {
        let items = model.data.items(for: kid.id)
        let scanned = Self.scannedApps(in: items)
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
                        Text("\(name(match)) · \(match.identifier)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Matched · \(matched.count)")
            } footer: {
                Text("Above: what \(kid.displayName)'s phone calls the app. Below: the app in Apple's usage data it was matched to.")
            }
            Section {
                ForEach(unmatched) { item in
                    ItemName(item: item)
                }
            } header: {
                Text("Not matched yet · \(unmatched.count)")
            } footer: {
                Text("An app is matched the first time it's used for about a minute on its own.")
            }
        }
        .navigationTitle("App matches")
    }

    /// Scanned apps still in the scan (they have a token), in the order the scan found them.
    static func scannedApps(in items: [UUID: TrackedItem]) -> [TrackedItem] {
        items.values.filter { $0.kind == .app && $0.isScanned && $0.tokenData != nil }
            .sorted { ($0.firstSeen, $0.identifier) < ($1.firstSeen, $1.identifier) }
    }

    private func name(_ item: TrackedItem) -> String {
        AppCatalog.shared.entries[item.identifier]?.name ?? item.displayName
    }
}
