import SwiftUI
import ThymeCore

/// A kid's custom categories (PLAN.md §15.14): each of Apple's categories with its last 7 days' use, opening to its
/// apps and websites, most used first. Tapping one moves it to another category, saved at once and noted in the
/// change history; moved ones are marked.
struct CustomCategoriesView: View {
    @Environment(AppModel.self) private var model
    let kid: Kid
    @State private var expanded: Set<String> = []

    /// One category's row: its group (nil for one not set up yet, or apps Apple named no category for) and use.
    private struct Row: Identifiable {
        var group: ItemGroup?
        var name: String?
        var seconds: Double
        var members: [CategoryUsage.App]
        var id: String { group?.id.uuidString ?? "name:" + (name ?? "") }
    }

    var body: some View {
        let policy = model.data.policy(for: kid.id)
        let items = model.data.items(for: kid.id)
        let custom = CustomCategories(policy: policy, items: items)
        let rows = rows(custom: custom, items: items)
        let most = rows.map(\.seconds).max() ?? 1
        List {
            RebuildingNotice()
            if custom.groups.isEmpty {
                Section { Text("No categories yet: they come from \(kid.displayName)'s use.").foregroundStyle(.secondary) }
            } else {
                Section {
                    ForEach(rows) { row in
                        DisclosureGroup(isExpanded: isExpanded(row.id)) {
                            if row.members.isEmpty {
                                Text("Nothing used in the last 7 days.").foregroundStyle(.secondary)
                            }
                            ForEach(row.members, id: \.id) { member in
                                memberRow(member, in: row.group, custom: custom, items: items)
                            }
                        } label: {
                            VStack(spacing: 6) {
                                LabeledContent {
                                    Text(Format.minutes(Int((row.seconds / 60).rounded()))).monospacedDigit()
                                } label: {
                                    if let group = row.group { GroupName(group: group) } else {
                                        Text(row.name ?? "No category").foregroundStyle(.secondary)
                                    }
                                }
                                ProgressView(value: min(row.seconds / max(most, 1), 1)).tint(kid.color)
                            }
                        }
                    }
                } header: {
                    Text("Last 7 days")
                } footer: {
                    Text("Tap an app or website to move it to another category. Downtime, limits, Always Allowed and Blocked then treat it as that category's, and the move is in the change history. \(Image(systemName: "arrow.uturn.right")) marks one moved. A browser's time on a website is the website's.")
                }
            }
        }
        .disabled(model.editsBlocked)
        .navigationTitle("Categories")
        .bugButton()
        .task { await model.setUpCustomCategories(for: kid) }
        .refreshable { await model.refresh() }
    }

    private func memberRow(_ member: CategoryUsage.App, in group: ItemGroup?, custom: CustomCategories,
                           items: [UUID: TrackedItem]) -> some View {
        let item = items[member.id]
        let apple = item?.category
        let moved = item.map { custom.moved[$0.id] != nil } ?? false
        return Menu {
            Section("Move to") {
                ForEach(custom.groups.filter { $0.id != group?.id }) { target in
                    Button(target.category == apple ? "\(target.name) (Apple's)" : target.name) {
                        Task { await model.move(member.id, to: target.id, kid: kid) }
                    }
                }
            }
        } label: {
            LabeledContent {
                Text(member.seconds > 0 ? RawUsageView.duration(member.seconds) : "").monospacedDigit()
            } label: {
                ItemName(item: item)
                if moved {
                    Label("Moved from \(apple ?? "no category")", systemImage: "arrow.uturn.right")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .tint(.primary)
    }

    /// Each custom category's use over the last 7 days, most first, with the moved apps and websites it holds even
    /// when unused. Websites take a browser's time on them.
    private func rows(custom: CustomCategories, items: [UUID: TrackedItem]) -> [Row] {
        let today = DayKey(Date())
        let websites = Set(items.values.filter { $0.kind == .domain }.map(\.id))
        let browsers = Set(items.values.filter { $0.kind == .app && BuiltInApps.showsWebsites($0.identifier) }.map(\.id))
        var seconds: [UUID: Double] = [:]
        for offset in 0..<7 {
            let samples = model.data.samples(kid: kid.id, day: today.adding(days: -offset))
            for sample in BrowserSites.attributed(samples, websites: websites, browsers: browsers) {
                seconds[sample.itemID, default: 0] += sample.seconds
            }
        }
        let mirrored = model.data.webMirrored(kid: kid.id, items: items, today: today)
        // Under a minute in a week isn't worth listing, unless it was moved.
        let used = CategoryUsage.build(seconds, items: custom.categorizing(items), excluding: mirrored)
            .map { category in
                var category = category
                category.apps.removeAll { $0.seconds < 60 && custom.moved[$0.id] == nil }
                return category
            }
        let byName = Dictionary(used.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var rows = custom.groups.map { group in
            var members = byName[group.category]?.apps ?? []
            let listed = Set(members.map(\.id))
            members += group.moved.filter { !listed.contains($0) && items[$0] != nil }
                .map { CategoryUsage.App(id: $0, seconds: 0) }
            return Row(group: group, name: group.name, seconds: byName[group.category]?.seconds ?? 0, members: members)
        }
        // Categories Apple's data names that have no group yet, and apps with none.
        let grouped = Set(custom.groups.compactMap(\.category))
        for category in used where category.name.map(grouped.contains) != true && !category.apps.isEmpty {
            rows.append(Row(group: nil, name: category.name, seconds: category.seconds, members: category.apps))
        }
        return rows.sorted { ($0.seconds, $1.name ?? "") > ($1.seconds, $0.name ?? "") }
    }

    private func isExpanded(_ id: String) -> Binding<Bool> {
        Binding {
            expanded.contains(id)
        } set: { open in
            if open { expanded.insert(id) } else { expanded.remove(id) }
        }
    }
}
