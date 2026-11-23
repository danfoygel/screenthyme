import SwiftUI
import ThymeCore

/// A kid's day by Apple's category (`CategoryUsage`): a row and bar for each, opening to its apps. On a parent's phone from
/// the family's data, on the kid's own phone from its App Group.
struct CategoryTimeView: View {
    @Environment(AppModel.self) private var model
    let source: KidTimelineView.Source
    @State var day: DayKey
    @State private var expanded: Set<String> = []

    var body: some View {
        let (categories, items, total) = data
        List {
            Section {
                HStack {
                    Button { day = day.adding(days: -1) } label: { Image(systemName: "chevron.left") }
                    Spacer()
                    Text(day.start().formatted(date: .complete, time: .omitted))
                    Spacer()
                    Button { day = day.adding(days: 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(day >= DayKey(Date()))
                }
                .buttonStyle(.borderless)
                LabeledContent("Apps (Apple's count)", value: Format.minutes(total.appMinutes))
                if total.uncountedMinutes > 0 {
                    LabeledContent("Uncounted", value: Format.minutes(total.uncountedMinutes))
                }
            } footer: {
                if total.uncountedMinutes > 0 {
                    Text("Uncounted apps are left out of the day's total. Their time still shows in their category.")
                }
            }
            if categories.isEmpty {
                Section { Text("No app use recorded.").foregroundStyle(.secondary) }
            } else {
                let most = categories.first?.seconds ?? 1
                Section {
                    ForEach(categories) { category in
                        DisclosureGroup(isExpanded: isExpanded(category)) {
                            ForEach(category.apps, id: \.id) { app in
                                ItemDetailsLink(item: items[app.id]) {
                                    LabeledContent {
                                        Text(Format.minutes(app.minutes)).monospacedDigit()
                                    } label: { ItemName(item: items[app.id]) }
                                }
                            }
                        } label: {
                            VStack(spacing: 6) {
                                LabeledContent {
                                    Text(Format.minutes(category.minutes)).monospacedDigit()
                                } label: { categoryName(category, items: items) }
                                ShareBar(share: category.seconds / most, tint: tint)
                            }
                        }
                    }
                } footer: {
                    Text("Apple puts each app in one category, mostly by its App Store category. Websites aren't counted here: their time is also Safari's.")
                }
            }
        }
        .navigationTitle("Categories")
        .bugButton()
        .refreshable {
            switch source {
            case .family: await model.refresh()
            case .thisPhone: await model.sampleNow()
            }
        }
    }

    private var data: ([CategoryUsage], [UUID: TrackedItem], DayTotal) {
        switch source {
        case .family(let kid):
            let items = model.data.items(for: kid.id)
            let timeline = model.timeline(kid: kid.id, day: day).timeline
            let mirrored = model.data.webMirrored(kid: kid.id, items: items, today: day)
            let total = DayTotal(timeline, items: items, policy: model.data.policy(on: day, kid: kid.id), mirrored: mirrored)
            return (CategoryUsage.build(timeline.items, items: items, excluding: mirrored), items, total)
        case .thisPhone:
            let items = Dictionary(AppGroup.loadItems().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let timeline = Reconstructor.build(model.config.dayInput(day))
            let mirrored = Enforcer.webMirrored(items)
            let policy = AppGroup.loadPolicy() ?? Policy(kidID: model.config.kid?.id ?? UUID())
            return (CategoryUsage.build(timeline.items, items: items, excluding: mirrored), items,
                    DayTotal(timeline, items: items, policy: policy, mirrored: mirrored))
        }
    }

    private var tint: Color {
        switch source {
        case .family(let kid): kid.color
        case .thisPhone: .accentColor
        }
    }

    private func title(_ category: CategoryUsage) -> String {
        category.name ?? "No category"
    }

    /// Apple's label for the category (its icon), when the phone has seen its token.
    @ViewBuilder
    private func categoryName(_ category: CategoryUsage, items: [UUID: TrackedItem]) -> some View {
        if let name = category.name,
           let item = items.values.first(where: { $0.kind == .category && $0.identifier == name && $0.tokenData != nil }) {
            ItemName(item: item)
        } else {
            Text(title(category)).foregroundStyle(category.name == nil ? .secondary : .primary)
        }
    }

    private func isExpanded(_ category: CategoryUsage) -> Binding<Bool> {
        Binding {
            expanded.contains(category.id)
        } set: { open in
            if open { expanded.insert(category.id) } else { expanded.remove(category.id) }
        }
    }
}

/// A bar as long as `share` of the row (0...1).
private struct ShareBar: View {
    let share: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(tint).frame(width: max(4, geometry.size.width * min(share, 1)))
        }
        .frame(height: 6)
    }
}
