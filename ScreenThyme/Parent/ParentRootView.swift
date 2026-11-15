import SwiftUI
import ThymeCore

struct ParentRootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            Tab("Kids", systemImage: "person.2") { ParentHomeView() }
            Tab("Alerts", systemImage: "bell") { AlertsView() }
            Tab("Settings", systemImage: "gear") { ParentSettingsView() }
        }
        // While open, poll every 30 s on top of push-triggered fetches (PLAN.md §4.3).
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
}

/// One card per kid: live status, today's total, top apps, health (PLAN.md §4.8).
struct ParentHomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                if model.config.family == nil {
                    Section {
                        Text("Set up your family in Settings, then send the invite to each kid's Apple Account.")
                    }
                }
                ForEach(model.data.sortedKids) { kid in
                    NavigationLink { KidDayView(kid: kid) } label: { KidCard(kid: kid) }
                }
            }
            .navigationTitle("Kids")
            .refreshable { await model.refresh() }
            .overlay {
                if model.data.kids.isEmpty && model.config.family != nil {
                    ContentUnavailableView("No kids yet", systemImage: "iphone",
                                           description: Text("Kids appear once their phone joins the family."))
                }
            }
        }
    }
}

struct KidCard: View {
    @Environment(AppModel.self) private var model
    let kid: Kid

    var body: some View {
        let today = DayKey(Date())
        let (input, timeline) = model.timeline(kid: kid.id, day: today)
        let items = model.data.items(for: kid.id)
        let live = LiveStatus.compute(timeline, input: input, now: Date())
        let issues = model.healthIssues(for: kid)
        let top = timeline.totals
            .filter { items[$0.key]?.kind != .category }
            .sorted { $0.value.lowerMinutes > $1.value.lowerMinutes }
            .prefix(3)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(kid.color).frame(width: 10, height: 10)
                Text(kid.displayName).font(.headline)
                if kid.isTest { Text("TEST").font(.caption2.bold()).foregroundStyle(.orange) }
                Spacer()
                Image(systemName: issues.contains(where: \.isUrgent) ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(issues.contains(where: \.isUrgent) ? .orange : .green)
            }
            HStack(spacing: 4) {
                if live.inUse {
                    Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.green)
                    Text("In use")
                    if let item = live.probableItem {
                        Text("· probably")
                        ItemName(item: items[item], showIcon: false)
                    }
                } else if let last = live.lastActiveAt ?? model.data.lastFireAt[kid.id] {
                    Text("Idle · last active \(Format.relative(last))").foregroundStyle(.secondary)
                } else {
                    Text("No use today").foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            Text("Today: \(Format.minutes(timeline.totalMinutes))").font(.subheadline.monospacedDigit())
            ForEach(Array(top), id: \.key) { id, total in
                HStack {
                    ItemName(item: items[id])
                    Spacer()
                    Text(Format.range(total)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}

struct KidDayView: View {
    @Environment(AppModel.self) private var model
    let kid: Kid
    @State private var day = DayKey(Date())

    var body: some View {
        let (_, timeline) = model.timeline(kid: kid.id, day: day)
        let items = model.data.items(for: kid.id)
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
                LabeledContent("Phone in use", value: Format.minutes(timeline.totalMinutes))
                LabeledContent("Not explained by tracked apps", value: Format.minutes(timeline.unexplainedMinutes))
                if timeline.preTrackingMinutes > 0 {
                    LabeledContent("Before tracking started (times unknown)",
                                   value: Format.minutes(timeline.preTrackingMinutes))
                }
            }
            Section {
                TimelineLanes(timeline: timeline, items: items, dayStart: day.start(), tint: kid.color)
            } footer: {
                Text("Solid: confident. Faded: inferred (catch-up bursts, or the minutes after an app's last 5-minute mark). Purple: several apps in quick succession. Tap a bar for times.")
            }
            Section("Apps") {
                ForEach(timeline.totals.filter { items[$0.key]?.kind != .category }
                    .sorted { $0.value.lowerMinutes > $1.value.lowerMinutes }, id: \.key) { id, total in
                    LabeledContent { Text(Format.range(total)).monospacedDigit() } label: { ItemName(item: items[id]) }
                }
            }
            let categories = timeline.totals.filter { items[$0.key]?.kind == .category }
            if !categories.isEmpty {
                Section("Categories") {
                    ForEach(categories.sorted { $0.value.lowerMinutes > $1.value.lowerMinutes }, id: \.key) { id, total in
                        LabeledContent { Text(Format.range(total)).monospacedDigit() } label: { ItemName(item: items[id]) }
                    }
                }
            }
            Section {
                NavigationLink("Rules and health") { KidSettingsView(kid: kid) }
            }
        }
        .navigationTitle(kid.displayName)
        .refreshable { await model.refresh() }
    }
}

struct AlertsView: View {
    @Environment(AppModel.self) private var model
    @State private var kidFilter: UUID?

    var body: some View {
        let alerts = model.data.alerts.values
            .filter { kidFilter == nil || $0.kidID == kidFilter }
            .sorted { $0.at > $1.at }
        NavigationStack {
            List {
                Picker("Kid", selection: $kidFilter) {
                    Text("All").tag(UUID?.none)
                    ForEach(model.data.sortedKids) { Text($0.displayName).tag(UUID?.some($0.id)) }
                }
                ForEach(alerts) { alert in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(alert.title).font(.headline)
                        Text(alert.body)
                        Text(alert.at.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Alerts")
            .refreshable { await model.refresh() }
            .overlay {
                if alerts.isEmpty { ContentUnavailableView("No alerts", systemImage: "bell.slash") }
            }
        }
    }
}
