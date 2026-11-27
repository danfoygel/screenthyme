import Foundation

/// The parents' version of Apple's categories (PLAN.md §15.14): a group for each (`ItemGroup.category`) holding Apple's
/// category items and the apps and websites moved into it from another category. Downtime, limits, Always Allowed,
/// Uncounted and Blocked name these groups, never Apple's categories. A moved app counts and is blocked only with its new
/// category: `categorizing` gives it that category for counting and lists, Apple's category shields let it through
/// (`movedOut`), and its own token is shielded with its new category (`Policy.resolved(items:)`).
public struct CustomCategories: Sendable {
    /// The custom categories, by name.
    public let groups: [ItemGroup]
    /// Each moved app and website → its custom category: the item moved, the scanned items matched to it (their tokens
    /// shield it) and, for a scanned item moved, its match.
    public let moved: [UUID: ItemGroup]

    public init(policy: Policy, items: [UUID: TrackedItem]) {
        groups = policy.groups.filter(\.isCategory).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        var moved: [UUID: ItemGroup] = [:]
        for group in groups {
            for id in group.moved.sorted(by: { $0.uuidString < $1.uuidString }) where moved[id] == nil {
                moved[id] = group
                if let match = items[id]?.match, moved[match] == nil { moved[match] = group }
            }
        }
        for item in items.values {
            if moved[item.id] == nil, let match = item.match, let group = moved[match] { moved[item.id] = group }
        }
        self.moved = moved
    }

    /// The category name `item` counts under: its custom category's for one moved, else Apple's.
    public func categoryName(of item: TrackedItem) -> String? {
        moved[item.id]?.category ?? item.category
    }

    /// The custom category `item` is in: the one it was moved to, else the one for Apple's category; nil for an app
    /// Apple named no category for, or whose category has no group yet.
    public func group(of item: TrackedItem) -> ItemGroup? {
        moved[item.id] ?? categoryName(of: item).flatMap { name in groups.first { $0.category == name } }
    }

    /// `items` with each moved app's and website's `category` its custom category's: what counting, category shields'
    /// exceptions and lists go by. Apple's category items stay as they are.
    public func categorizing(_ items: [UUID: TrackedItem]) -> [UUID: TrackedItem] {
        guard !moved.isEmpty else { return items }
        var items = items
        for (id, group) in moved where items[id] != nil && items[id]?.kind != .category {
            items[id]?.category = group.category
        }
        return items
    }

    /// Apps and websites Apple puts in one of `categories` (names) that were moved to another: a shield of those
    /// categories lets them through, and iOS's threshold event for them would count them. `items` as Apple has them.
    public func movedOut(of categories: Set<String>, items: [UUID: TrackedItem]) -> Set<UUID> {
        guard !categories.isEmpty else { return [] }
        return Set(moved.compactMap { id, group in
            guard let item = items[id] else { return nil }
            let apple = item.category ?? item.match.flatMap { items[$0]?.category }
            guard let apple, categories.contains(apple), apple != group.category else { return nil }
            return id
        })
    }

    /// The apps and websites moved into the custom categories for `categories` (names).
    public func movedIn(to categories: Set<String>) -> Set<UUID> {
        guard !categories.isEmpty else { return [] }
        return Set(moved.filter { $0.value.category.map(categories.contains) == true }.keys)
    }
}

extension Policy {
    /// A custom category's id: the same on every parent's phone, so two phones setting up categories agree.
    public static func categoryGroupID(kid: UUID, category: String) -> UUID {
        Replay.stableUUID("custom-category", kid.uuidString, category)
    }

    /// The policy with a custom category for each of Apple's categories the kid's phone has seen, each holding Apple's
    /// category items for it (scanned ones matched later join), and every use of an Apple category (Downtime, limits,
    /// Always Allowed, Uncounted, Blocked, and what temporary changes change back to) naming its custom category
    /// instead. The parents' own groups keep Apple's categories (groups don't nest); those stand for the custom
    /// categories anyway (`resolved(items:)`). Doing it twice changes nothing.
    public func withCustomCategories(items: [UUID: TrackedItem]) -> Policy {
        // Category items by Apple's name: their own, or a scanned one's match's.
        var byName: [String: Set<UUID>] = [:]
        for item in items.values where item.kind == .category && item.kidID == kidID {
            let name = item.isScanned ? item.match.flatMap { items[$0] }?.identifier : item.identifier
            if let name { byName[name, default: []].insert(item.id) }
        }
        var policy = self
        var groupOf: [UUID: UUID] = [:]
        for (name, ids) in byName.sorted(by: { $0.key < $1.key }) {
            let id = Self.categoryGroupID(kid: kidID, category: name)
            if let index = policy.groups.firstIndex(where: { $0.id == id }) {
                policy.groups[index].items.formUnion(ids)
            } else {
                policy.groups.append(ItemGroup(id: id, name: name, items: ids, category: name))
            }
            for item in ids { groupOf[item] = id }
        }
        guard !groupOf.isEmpty else { return self }
        policy.replaceCategories(groupOf)
        for index in policy.temporary.indices {
            policy.temporary[index].before.replaceCategories(groupOf)
            policy.temporary[index].after.replaceCategories(groupOf)
        }
        return policy
    }

    /// Apple's category items named in Downtime, limits, Always Allowed, Uncounted and Blocked (every ruleset's) → their
    /// custom category.
    private mutating func replaceCategories(_ groupOf: [UUID: UUID]) {
        func replace(_ ids: Set<UUID>) -> Set<UUID> { Set(ids.map { groupOf[$0] ?? $0 }) }
        // Uncounted first: setting Always Allowed keeps only Uncounted entries it holds.
        let uncounted = replace(self.uncounted)
        alwaysAllowed = replace(alwaysAllowed)
        self.uncounted = uncounted
        editAllRules { downtime, limits, blocked in
            blocked = replace(blocked)
            for index in limits.indices { limits[index].items = replace(limits[index].items) }
            for index in downtime.indices { downtime[index].items = replace(downtime[index].items) }
        }
    }

    /// Moves an app or website (Apple's item) to custom category `groupID`, or with nil back to Apple's category. Moving
    /// one to the custom category of Apple's own category for it is moving it back.
    public mutating func move(_ itemID: UUID, to groupID: UUID?, items: [UUID: TrackedItem]) {
        for index in groups.indices where groups[index].isCategory { groups[index].moved.remove(itemID) }
        guard let groupID, let index = groups.firstIndex(where: { $0.id == groupID && $0.isCategory }) else { return }
        let apple = items[itemID]?.category
        if groups[index].category != apple { groups[index].moved.insert(itemID) }
    }
}
