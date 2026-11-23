import Foundation

/// A day's use of one of Apple's categories ("Games"): its apps' totals, under the category Apple's data gives each app.
/// Websites are left out (their time is also Safari's), and so are apps whose use was Safari's on their website
/// (`WebMirror`), so the categories add up to the day's "Apps (Apple's count)".
public struct CategoryUsage: Sendable, Hashable, Identifiable {
    /// An app's seconds in the category.
    public struct App: Sendable, Hashable {
        public var id: UUID
        public var seconds: Double

        public var minutes: Int { Int((seconds / 60).rounded()) }
    }

    /// Apple's category name, the identifier of its category item; nil for apps Apple's data named none for.
    public var name: String?
    public var seconds: Double
    /// Most used first.
    public var apps: [App]

    public var id: String { name ?? "" }
    public var minutes: Int { Int((seconds / 60).rounded()) }

    /// The categories used in a day (`DayTimeline.items`), most used first.
    public static func build(_ usage: [UUID: ItemUsage], items: [UUID: TrackedItem],
                             excluding mirrored: Set<UUID> = []) -> [CategoryUsage] {
        var byName: [String?: [App]] = [:]
        for (id, use) in usage where use.seconds > 0 && !mirrored.contains(id) {
            let item = items[id]
            guard item?.kind != .domain, item?.kind != .category else { continue }
            byName[item?.category, default: []].append(App(id: id, seconds: use.seconds))
        }
        return byName.map { name, apps in
            CategoryUsage(name: name, seconds: apps.reduce(0) { $0 + $1.seconds },
                          apps: apps.sorted { ($0.seconds, $1.id.uuidString) > ($1.seconds, $0.id.uuidString) })
        }
        .sorted { ($0.seconds, $1.name ?? "") > ($1.seconds, $0.name ?? "") }
    }
}
