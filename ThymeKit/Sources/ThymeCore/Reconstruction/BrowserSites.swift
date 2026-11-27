import Foundation

/// Apple counts a browser's use twice: under its bundle ID and under the domain of the site it showed (Chrome's minutes
/// matched one site's second for second on a kid's phone). A Home Screen web app's goes under one bundle ID shared by
/// every web app, and under its site's. Lists show that time as the sites', and the browser keeps the rest (a new tab,
/// its settings). Limits and shields still go by Apple's numbers: iOS counts a browser's own token by them.
///
/// Apple counts a web view inside any other app too: an ad (googleads.g.doubleclick.net, imasdk.googleapis.com) or an
/// in-app browser has its site's time beside the app's own, which already holds it. A banner ad on screen for a whole
/// game had hours. A site's time that no browser in its fetch can account for was in such an app, so lists leave it out.
public enum BrowserSites {
    /// How a fetch's website use splits, by sample id.
    struct Split {
        /// Each browser sample's share of each site's use.
        var shares: [UUID: [UUID: Double]] = [:]
        /// Each site sample's seconds no browser can account for: inside another app's.
        var inApps: [UUID: Double] = [:]
    }

    /// Each browser sample's share of the websites' use in its fetch (the same window), up to its own seconds. A site's
    /// seconds go out once, busiest browser first, so Safari and Chrome in one fetch don't both take a site. What's left
    /// of a site was inside another app.
    static func split(_ samples: [UsageSample], websites: Set<UUID>, browsers: Set<UUID>) -> Split {
        var split = Split()
        for (_, fetch) in Dictionary(grouping: samples, by: Window.init) {
            let sites = fetch.filter { websites.contains($0.itemID) }
            guard !sites.isEmpty else { continue }
            var left = Dictionary(sites.map { ($0.id, $0.seconds) }, uniquingKeysWith: +)
            let ordered = fetch.filter { browsers.contains($0.itemID) }
                .sorted { ($0.seconds, $0.itemID.uuidString) > ($1.seconds, $1.itemID.uuidString) }
            for sample in ordered {
                var own = sample.seconds
                while own > 0, let site = bestMatch(sites, left: left, own: own) {
                    let taken = min(own, left[site.id] ?? 0)
                    split.shares[sample.id, default: [:]][site.itemID, default: 0] += taken
                    left[site.id]? -= taken
                    own -= taken
                }
            }
            for (id, seconds) in left where seconds > 0 { split.inApps[id] = seconds }
        }
        return split
    }

    /// The site a browser's `own` seconds most likely showed: the busiest that fits in them whole, else the one closest
    /// to them. An ad inside a game can have far more time than the site read in Safari beside it, so the busiest
    /// isn't it.
    private static func bestMatch(_ sites: [UsageSample], left: [UUID: Double], own: Double) -> UsageSample? {
        let open = sites.filter { (left[$0.id] ?? 0) > 0 }
        let fits = open.filter { left[$0.id]! <= own }
        if let best = fits.max(by: { (left[$0.id]!, $1.itemID.uuidString) < (left[$1.id]!, $0.itemID.uuidString) }) {
            return best
        }
        return open.min { (left[$0.id]!, $0.itemID.uuidString) < (left[$1.id]!, $1.itemID.uuidString) }
    }

    /// The samples with each browser's time on websites taken off it (the sites' own samples already count it), and
    /// each site's time inside other apps taken off the site (the apps' samples already count it).
    public static func attributed(_ samples: [UsageSample], websites: Set<UUID>, browsers: Set<UUID>) -> [UsageSample] {
        let split = split(samples, websites: websites, browsers: browsers)
        guard !split.shares.isEmpty || !split.inApps.isEmpty else { return samples }
        return samples.map { sample in
            let taken = (split.shares[sample.id]?.values.reduce(0, +) ?? 0) + (split.inApps[sample.id] ?? 0)
            guard taken > 0 else { return sample }
            var sample = sample
            sample.seconds = max(0, sample.seconds - taken)
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
