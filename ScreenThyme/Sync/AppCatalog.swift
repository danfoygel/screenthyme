import Foundation
import Observation
import ThymeCore

/// Real names and icons for the bundle IDs in Apple's data (PLAN.md §15.5), from the App Store's public lookup, cached
/// on a parent's phone. Apple's built-in apps aren't in the store: `BuiltInApps` names those.
@MainActor @Observable
final class AppCatalog {
    static let shared = AppCatalog()

    struct Entry: Codable {
        var name: String
        var icon: URL?
    }

    private(set) var entries: [String: Entry] = [:]
    /// Looked up this launch and not in the store.
    private var unknown: Set<String> = []
    private let url = URL.applicationSupportDirectory.appending(path: "app-catalog.json")

    private init() {
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        }
    }

    /// The name to show and sort by: nickname, the App Store's name, or the item's own (a scanned app goes by its match).
    func name(of item: TrackedItem, in items: [UUID: TrackedItem]) -> String? {
        if let nickname = item.nickname { return nickname }
        if item.isScanned { return item.match.flatMap { items[$0] }.flatMap { name(of: $0, in: items) } }
        return item.kind == .app ? entries[item.identifier]?.name ?? item.displayName : item.displayName
    }

    func icon(for item: TrackedItem) -> URL? {
        item.kind == .app ? entries[item.identifier]?.icon : nil
    }

    func lookUp(_ items: some Sequence<TrackedItem>) async {
        let bundles = Set(items.filter { $0.kind == .app && !$0.isScanned }.map(\.identifier))
            .filter { entries[$0] == nil && !unknown.contains($0) && BuiltInApps.names[$0] == nil }
        guard !bundles.isEmpty else { return }
        for bundle in bundles {
            var components = URLComponents(string: "https://itunes.apple.com/lookup")!
            components.queryItems = [URLQueryItem(name: "bundleId", value: bundle)]
            guard let (data, _) = try? await URLSession.shared.data(from: components.url!),
                  let found = (try? JSONDecoder().decode(Lookup.self, from: data))?.results.first else {
                unknown.insert(bundle)
                continue
            }
            entries[bundle] = Entry(name: found.trackName, icon: found.artworkUrl60.flatMap(URL.init(string:)))
        }
        try? JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }

    private struct Lookup: Decodable {
        struct App: Decodable {
            var trackName: String
            var artworkUrl60: String?
        }
        var results: [App]
    }
}
