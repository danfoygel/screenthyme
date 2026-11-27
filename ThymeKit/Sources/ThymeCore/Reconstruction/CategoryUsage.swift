import Foundation

/// Use of one category ("Games"): its apps' and websites' totals, under the category Apple's data gives each, or the
/// custom category it was moved to (pass items through `CustomCategories.categorizing`). Use should give a browser's
/// time on websites to the sites, and leave out a website's time inside other apps (`DayTimeline.attributed`,
/// `BrowserSites`), so nothing counts twice. Apps whose use was Safari's on their website (`WebMirror`) are left out.
public struct CategoryUsage: Sendable, Hashable, Identifiable {
    /// An app's or website's seconds in the category.
    public struct App: Sendable, Hashable {
        public var id: UUID
        public var seconds: Double

        public init(id: UUID, seconds: Double) {
            self.id = id
            self.seconds = seconds
        }

        public var minutes: Int { Int((seconds / 60).rounded()) }
    }

    /// Apple's category name, the identifier of its category item; nil for apps Apple's data named none for.
    public var name: String?
    public var seconds: Double
    /// Most used first.
    public var apps: [App]

    public var id: String { name ?? "" }
    public var minutes: Int { Int((seconds / 60).rounded()) }

    /// The categories used, most used first, from each item's seconds.
    public static func build(_ usage: [UUID: Double], items: [UUID: TrackedItem],
                             excluding mirrored: Set<UUID> = []) -> [CategoryUsage] {
        var byName: [String?: [App]] = [:]
        for (id, seconds) in usage where seconds > 0 && !mirrored.contains(id) {
            let item = items[id]
            guard item?.kind != .category, item?.isScanned != true else { continue }
            byName[item?.category, default: []].append(App(id: id, seconds: seconds))
        }
        return byName.map { name, apps in
            CategoryUsage(name: name, seconds: apps.reduce(0) { $0 + $1.seconds },
                          apps: apps.sorted { ($0.seconds, $1.id.uuidString) > ($1.seconds, $0.id.uuidString) })
        }
        .sorted { ($0.seconds, $1.name ?? "") > ($1.seconds, $0.name ?? "") }
    }
}
