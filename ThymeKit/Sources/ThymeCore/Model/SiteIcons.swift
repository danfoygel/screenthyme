import Foundation

/// Where to find a website's own icon, for parents' phones (`AppCatalog`).
public enum SiteIcons {
    /// The hosts to try: the domain, then its parent domain ("googleads.g.doubleclick.net" → "doubleclick.net").
    public static func hosts(for domain: String) -> [String] {
        let labels = domain.lowercased().split(separator: ".")
        guard labels.count > 2 else { return [domain.lowercased()] }
        return [domain.lowercased(), labels.suffix(2).joined(separator: ".")]
    }

    /// Icons a home page names, best first: touch icons (big, square), then other icons by size. SVGs are left out
    /// (UIImage can't draw them); after these, try `fallbacks`.
    public static func linked(in html: String, base: URL) -> [URL] {
        var found: [(touch: Bool, size: Int, url: URL)] = []
        for match in html.matches(of: /<link\b[^>]*>/.ignoresCase()) {
            let tag = String(match.output)
            guard let rel = attribute("rel", in: tag)?.lowercased(), let href = attribute("href", in: tag) else { continue }
            let rels = rel.split(separator: " ")
            let touch = rels.contains { $0.hasPrefix("apple-touch-icon") }
            guard touch || rels.contains("icon") else { continue }
            let type = attribute("type", in: tag)?.lowercased() ?? ""
            guard !type.contains("svg"),
                  let url = URL(string: href.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: base)?.absoluteURL,
                  url.scheme == "https" || url.scheme == "http", !url.path.lowercased().hasSuffix(".svg") else { continue }
            let size = attribute("sizes", in: tag)?.lowercased().split(separator: "x").first.flatMap { Int($0) } ?? 0
            found.append((touch, size, url))
        }
        var seen = Set<URL>()
        return found.enumerated()
            .sorted { ($0.element.touch ? 1 : 0, $0.element.size, -$0.offset) > ($1.element.touch ? 1 : 0, $1.element.size, -$1.offset) }
            .map(\.element.url)
            .filter { seen.insert($0).inserted }
    }

    /// Where most sites keep an icon without naming it.
    public static func fallbacks(host: String) -> [URL] {
        ["apple-touch-icon.png", "favicon.ico"].compactMap { URL(string: "https://\(host)/\($0)") }
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = try! Regex("\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))").ignoresCase()
        guard let match = tag.firstMatch(of: pattern) else { return nil }
        return (1...3).lazy.compactMap { match.output[$0].substring.map(String.init) }.first
    }
}
