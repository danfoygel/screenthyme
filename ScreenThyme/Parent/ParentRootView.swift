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
                await AppCatalog.shared.lookUp(model.data.kids.keys.flatMap { model.data.items(for: $0).values })
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
            .bugButton()
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
        let top = timeline.items.filter { items[$0.key]?.kind != .domain }.sorted { $0.value.seconds > $1.value.seconds }.prefix(3)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(kid.color).frame(width: 10, height: 10)
                Text(kid.displayName).font(.headline)
                if kid.isTest { Text("TEST").font(.caption2.bold()).foregroundStyle(.orange) }
                Spacer()
                if model.nearby.isConnected(kid: kid.id) {
                    Label("Nearby", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Image(systemName: issues.contains(where: \.isUrgent) ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(issues.contains(where: \.isUrgent) ? .orange : .green)
            }
            HStack(spacing: 4) {
                if live.inUse {
                    Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.green)
                    Text("In use")
                    if let item = live.probableItem {
                        Text("·")
                        ItemName(item: items[item], showIcon: false)
                    }
                } else if let last = live.lastActiveAt ?? model.data.lastFireAt[kid.id] {
                    Text("Idle · last active \(Format.relative(last))").foregroundStyle(.secondary)
                } else {
                    Text("No use today").foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            Text("Today: \(Format.minutes(max(timeline.totalMinutes, appTotal(timeline, items))))").font(.subheadline.monospacedDigit())
            let toMatch = model.appsToMatch(for: kid).count
            if toMatch > 0 {
                Label("\(toMatch) new \(toMatch == 1 ? "app" : "apps") to match", systemImage: "qrcode.viewfinder")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ForEach(Array(top), id: \.key) { id, usage in
                HStack {
                    ItemName(item: items[id])
                    Spacer()
                    Text(Format.minutes(usage.minutes)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Apple's total over apps only: websites also count as Safari's time.
func appTotal(_ timeline: DayTimeline, _ items: [UUID: TrackedItem]) -> Int {
    Int((timeline.items.filter { items[$0.key]?.kind != .domain }.values.reduce(0) { $0 + $1.seconds } / 60).rounded())
}

struct KidDayView: View {
    @Environment(AppModel.self) private var model
    let kid: Kid
    @State private var day = DayKey(Date())

    var body: some View {
        let (_, timeline) = model.timeline(kid: kid.id, day: day)
        let items = model.data.items(for: kid.id)
        let used = timeline.items.sorted { $0.value.seconds > $1.value.seconds }
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
                LabeledContent("Apps (Apple's count)", value: Format.minutes(appTotal(timeline, items)))
                LabeledContent("Phone in use", value: Format.minutes(timeline.totalMinutes))
            }
            let toMatch = model.appsToMatch(for: kid)
            if !toMatch.isEmpty {
                Section {
                    NavigationLink { PairingScannerView(kid: kid) } label: {
                        Label("Match \(toMatch.count) new \(toMatch.count == 1 ? "app" : "apps") with camera",
                              systemImage: "qrcode.viewfinder")
                            .foregroundStyle(.orange)
                    }
                    ForEach(toMatch.prefix(5)) { item in ItemName(item: item).font(.subheadline) }
                    if toMatch.count > 5 {
                        Text("and \(toMatch.count - 5) more").font(.subheadline).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Used on \(kid.displayName)'s phone since its last match, so limits don't count them yet. Apps installed since the last app scan need a new scan on that phone first.")
                }
            }
            Section {
                NavigationLink { KidTimelineView(kid: kid, day: day) } label: {
                    Label("Day timeline", systemImage: "calendar.day.timeline.left")
                }
                NavigationLink { PolicyHistoryView(kid: kid) } label: {
                    Label("Change history", systemImage: "clock.arrow.circlepath")
                }
            }
            Section {
                TimelineLanes(timeline: timeline, items: items, dayStart: day.start(), tint: kid.color)
            } footer: {
                Text("Apple counts each app's use between two of the phone's check-ins (every 2 minutes of use); each block puts that count on the minutes just before an on-time check-in. Fainter means the app was in use for only part of that time. Tap a block for times.")
            }
            Section("Apps") {
                ForEach(used.filter { items[$0.key]?.kind != .domain }, id: \.key) { id, usage in
                    ItemDetailsLink(item: items[id]) {
                        LabeledContent { Text(Format.minutes(usage.minutes)).monospacedDigit() } label: { ItemName(item: items[id]) }
                    }
                }
            }
            let sites = used.filter { items[$0.key]?.kind == .domain }
            if !sites.isEmpty {
                Section("Websites") {
                    ForEach(sites, id: \.key) { id, usage in
                        ItemDetailsLink(item: items[id]) {
                            LabeledContent { Text(Format.minutes(usage.minutes)).monospacedDigit() } label: { ItemName(item: items[id]) }
                        }
                    }
                }
            }
            Section {
                NavigationLink("Rules and health") { KidSettingsView(kid: kid) }
            }
        }
        .navigationTitle(kid.displayName)
        .bugButton()
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
                let requests = model.data.openRequests.filter { kidFilter == nil || $0.kidID == kidFilter }
                if !requests.isEmpty {
                    Section("Asking for more time") {
                        ForEach(requests) { RequestRow(request: $0) }
                    }
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
            .bugButton()
            .refreshable { await model.refresh() }
            .overlay {
                if alerts.isEmpty { ContentUnavailableView("No alerts", systemImage: "bell.slash") }
            }
        }
    }
}

/// A kid's request for more time, with the answers a parent can give.
struct RequestRow: View {
    @Environment(AppModel.self) private var model
    let request: TimeRequest

    var body: some View {
        let kid = model.data.kids[request.kidID]?.displayName ?? "Your kid"
        let item = request.itemID.flatMap { model.data.items[$0] }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let item { ItemName(item: item) }
                Spacer()
                Text(Format.relative(request.at)).font(.caption).foregroundStyle(.secondary)
            }
            Text("\(kid) asks for \(ShieldContext.describe(minutes: request.minutes)) \(reason).")
            if let note = request.note {
                Text("\u{201C}\(note)\u{201D}").italic()
            }
            HStack {
                Button("Approve") { answer(true, request.minutes) }
                    .buttonStyle(.borderedProminent)
                Menu("Other") {
                    ForEach(ShieldContext.requestChoices.filter { $0 != request.minutes }, id: \.self) { minutes in
                        Button(ShieldContext.describe(minutes: minutes).capitalizedFirst) { answer(true, minutes) }
                    }
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Decline", role: .destructive) { answer(false, nil) }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var reason: String {
        Self.describe(request.reason, itemID: request.itemID, policy: model.data.policy(for: request.kidID))
    }

    /// "during Bedtime", "over the Games limit".
    static func describe(_ reason: BlockReason, itemID: UUID?, policy: Policy) -> String {
        switch reason {
        case let .downtime(id):
            let name = policy.downtime.first { $0.id == id }?.name ?? "Downtime"
            return itemID == nil ? "during \(name), for the whole phone" : "during \(name)"
        case let .limit(id): return "over the \(policy.limits.first { $0.id == id }?.name ?? "time") limit"
        case .blocked: return "for a blocked app"
        }
    }

    private func answer(_ approved: Bool, _ minutes: Int?) {
        Task { await model.answer(request, approved: approved, minutes: minutes) }
    }
}
