import Foundation

/// Apple counts a browser's use twice: under its bundle ID and under the domain of the site it showed (Chrome's minutes
/// matched one site's second for second on a kid's phone). A Home Screen web app's goes under one bundle ID shared by
/// every web app, and under its site's. Lists show that time as the sites', and the browser keeps the rest (a new tab,
/// its settings). Limits and shields still go by Apple's numbers: iOS counts a browser's own token by them.
public enum BrowserSites {
    /// Each browser sample's share of the websites' use in its fetch (the same window), up to its own seconds, by
    /// sample id. A site's seconds go out once, busiest browser first, so Safari and Chrome in one fetch don't both take
    /// a site.
    static func shares(_ samples: [UsageSample], websites: Set<UUID>, browsers: Set<UUID>) -> [UUID: [UUID: Double]] {
        guard !browsers.isEmpty else { return [:] }
        var shares: [UUID: [UUID: Double]] = [:]
        for (_, fetch) in Dictionary(grouping: samples, by: Window.init) {
            let sites = fetch.filter { websites.contains($0.itemID) }
            guard !sites.isEmpty else { continue }
            var left = Dictionary(sites.map { ($0.id, $0.seconds) }, uniquingKeysWith: +)
            let ordered = fetch.filter { browsers.contains($0.itemID) }
                .sorted { ($0.seconds, $0.itemID.uuidString) > ($1.seconds, $1.itemID.uuidString) }
            for sample in ordered {
                var own = sample.seconds
                // The best match first: the site with the most use left.
                for site in sites.sorted(by: { (left[$0.id] ?? 0, $0.itemID.uuidString) > (left[$1.id] ?? 0, $1.itemID.uuidString) }) {
                    let taken = min(own, left[site.id] ?? 0)
                    guard taken > 0 else { continue }
                    shares[sample.id, default: [:]][site.itemID, default: 0] += taken
                    left[site.id]? -= taken
                    own -= taken
                }
            }
        }
        return shares
    }

    /// The samples with each browser's time on websites taken off it (the sites' own samples already count it).
    public static func attributed(_ samples: [UsageSample], websites: Set<UUID>, browsers: Set<UUID>) -> [UsageSample] {
        let shares = shares(samples, websites: websites, browsers: browsers)
        guard !shares.isEmpty else { return samples }
        return samples.map { sample in
            guard let taken = shares[sample.id] else { return sample }
            var sample = sample
            sample.seconds = max(0, sample.seconds - taken.values.reduce(0, +))
            return sample
        }
    }

    /// A fetch's window: its samples share a start and end, rounded apart by under a second.
    private struct Window: Hashable {
        var start: Int
        var end: Int

        init(_ sample: UsageSample) {
            start = Int(sample.start.timeIntervalSince1970.rounded())
            end = Int(sample.end.timeIntervalSince1970.rounded())
        }
    }
}
