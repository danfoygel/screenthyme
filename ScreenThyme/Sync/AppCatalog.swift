import Foundation
import ManagedSettings
import Observation
import ThymeCore
import UIKit

/// Real names and icons for the bundle IDs and domains in Apple's data (PLAN.md §15.6), cached on a parent's phone.
/// Apps come from the App Store's public lookup, which knows most of Apple's own apps too (`BuiltInApps` keeps their
/// short names); websites from the sites themselves. Settings and App Store aren't in the store: they take the icon
/// of the scanned item matched to them, and Settings, which the scan never offers, gets a drawn gear.
@MainActor @Observable
final class AppCatalog {
    static let shared = AppCatalog()

    struct Entry: Codable {
        var name: String
        var icon: URL?
    }

    enum Icon {
        case remote(URL)
        case image(UIImage)
        case token(ApplicationToken)
        /// An SF Symbol on a gray tile, for an Apple app with no icon anywhere we can reach.
        case symbol(String)
    }

    private static let symbols = ["com.apple.Preferences": "gearshape.fill"]

    /// By bundle ID.
    private(set) var entries: [String: Entry] = [:]
    /// By domain.
    private(set) var siteIcons: [String: URL] = [:]
    /// Item ID → the token of the scanned item matched to it.
    private var matchedTokens: [UUID: Data] = [:]
    /// Looked up this launch and not found.
    private var unknown: Set<String> = []
    private let url = URL.applicationSupportDirectory.appending(path: "app-catalog.json")
    private let sitesURL = URL.applicationSupportDirectory.appending(path: "site-icons.json")

    private init() {
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        }
        if let data = try? Data(contentsOf: sitesURL), let saved = try? JSONDecoder().decode([String: URL].self, from: data) {
            siteIcons = saved
        }
    }

    /// The name to show and sort by: nickname, the App Store's name, or the item's own (a scanned app goes by its match).
    func name(of item: TrackedItem, in items: [UUID: TrackedItem]) -> String? {
        if let nickname = item.nickname { return nickname }
        if item.isScanned { return item.match.flatMap { items[$0] }.flatMap { name(of: $0, in: items) } }
        return item.kind == .app ? entries[item.identifier]?.name ?? item.displayName : item.displayName
    }

    func icon(for item: TrackedItem) -> Icon? {
        switch item.kind {
        case .app:
            if let url = entries[item.identifier]?.icon { return .remote(url) }
            if item.identifier == Bundle.main.bundleIdentifier, let own = Self.ownIcon { return .image(own) }
            if let token = TokenCoding.application(matchedTokens[item.id]) { return .token(token) }
            return Self.symbols[item.identifier].map(Icon.symbol)
        case .domain:
            return siteIcons[item.identifier].map(Icon.remote)
        case .category:
            return nil
        }
    }

    func lookUp(_ items: some Sequence<TrackedItem>) async {
        let items = Array(items)
        matchedTokens = Dictionary(items.compactMap { item in item.match.flatMap { id in item.tokenData.map { (id, $0) } } },
                                   uniquingKeysWith: { a, _ in a })
        await lookUpApps(Set(items.filter { $0.kind == .app && !$0.isScanned }.map(\.identifier)))
        await lookUpSites(Set(items.filter { $0.kind == .domain && !$0.isScanned }.map(\.identifier)))
    }

    private func lookUpApps(_ bundles: Set<String>) async {
        let bundles = bundles.filter { entries[$0] == nil && !unknown.contains($0) }
        guard !bundles.isEmpty else { return }
        for bundle in bundles {
            if bundle == Bundle.main.bundleIdentifier {
                entries[bundle] = Entry(name: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "ScreenThyme")
                continue
            }
            var components = URLComponents(string: "https://itunes.apple.com/lookup")!
            components.queryItems = [URLQueryItem(name: "bundleId", value: bundle)]
            guard let (data, _) = try? await URLSession.shared.data(from: components.url!),
                  let found = (try? JSONDecoder().decode(Lookup.self, from: data))?.results.first else {
                unknown.insert(bundle)
                continue
            }
            // The store says "Apple Music"; the phone says "Music".
            entries[bundle] = Entry(name: BuiltInApps.names[bundle] ?? found.trackName,
                                    icon: found.artworkUrl60.flatMap(URL.init(string:)))
        }
        try? JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }

    private func lookUpSites(_ domains: Set<String>) async {
        let domains = domains.filter { siteIcons[$0] == nil && !unknown.contains($0) }
        guard !domains.isEmpty else { return }
        let found = await withTaskGroup(of: (String, URL?).self) { group in
            for domain in domains {
                group.addTask { (domain, await Self.siteIcon(domain)) }
            }
            var found: [(String, URL?)] = []
            for await result in group { found.append(result) }
            return found
        }
        for (domain, icon) in found {
            if let icon { siteIcons[domain] = icon } else { unknown.insert(domain) }
        }
        try? JSONEncoder().encode(siteIcons).write(to: sitesURL, options: .atomic)
    }

    /// The first icon that loads: one the home page names, else a usual path, for the domain and then its parent's.
    private nonisolated static func siteIcon(_ domain: String) async -> URL? {
        let session = URLSession(configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            return configuration
        }())
        defer { session.finishTasksAndInvalidate() }
        for host in SiteIcons.hosts(for: domain) {
            let home = URL(string: "https://\(host)/")!
            var candidates: [URL] = []
            if let (data, response) = try? await session.data(from: home) {
                candidates += SiteIcons.linked(in: String(decoding: data.prefix(500_000), as: UTF8.self),
                                               base: response.url ?? home)
            }
            for candidate in candidates + SiteIcons.fallbacks(host: host) {
                if let (data, response) = try? await session.data(from: candidate),
                   (response as? HTTPURLResponse)?.statusCode == 200,
                   let image = UIImage(data: data), image.size.width >= 16 {
                    return candidate
                }
            }
        }
        return nil
    }

    /// The parent's own copy of ScreenThyme's icon, for the kid's ScreenThyme (not in the store).
    private static let ownIcon: UIImage? = {
        let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        return (primary?["CFBundleIconFiles"] as? [String])?.last.flatMap { UIImage(named: $0) }
            ?? (primary?["CFBundleIconName"] as? String).flatMap { UIImage(named: $0) }
    }()

    private struct Lookup: Decodable {
        struct App: Decodable {
            var trackName: String
            var artworkUrl60: String?
        }
        var results: [App]
    }
}
