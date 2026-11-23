import Charts
import SwiftUI
import ThymeCore

/// One app or website, on parents' phones and the kid's (`AppDetails`): whether it's blocked now, its use over the
/// last month, the groups and lists it's in, the Downtime and limits that cover it, and the kid's requests for it.
struct AppDetailsView: View {
    @Environment(AppModel.self) private var model
    let item: TrackedItem
    /// The kid's phone reads its App Group once per visit (its samples file holds every day).
    @State private var kidData: AppDetailsData?

    var body: some View {
        let data = model.isParent ? AppDetailsData.parent(model.data, kid: item.kidID) : kidData ?? .empty
        let details = AppDetails(item: item, items: data.items, policy: data.policy, exempt: Enforcer.exemptItems(data.items))
        let today = DayKey(Date())
        let usage = details.usage(today: today, samples: data.samples)
        let shown = details.tokenItem ?? item
        List {
            Section {
                ItemName(item: shown).font(.title3.weight(.semibold))
                StatusRow(status: data.hasPolicy ? data.plan.map { details.status(in: $0, policy: data.policy) } : nil,
                          hasPolicy: data.hasPolicy)
            } footer: {
                if details.usageItem == nil {
                    Text("Not matched to Apple's data yet, so its use isn't known.")
                } else if details.tokenItem == nil {
                    Text("Not matched to the app scan yet, so ScreenThyme can block it only through its category or Downtime for the whole phone.")
                }
            }
            usageSection(usage, details: details, data: data, name: AppCatalog.shared.name(of: shown, in: data.items))
            if model.isParent {
                AppLocationsSection(kid: item.kidID, ids: details.ids)
            }
            if usage.last30Days > 0 {
                Section {
                    UsageHeatmapView(heatmap: UsageHeatmap.build(today: today, now: Date(), samples: data.samples,
                                                                 counts: { details.ids.contains($0.itemID) }))
                } header: {
                    Text("When")
                } footer: {
                    Text(UsageHeatmapView.footer)
                }
            }
            groupsSection(details, data: data)
            downtimeSection(details, data: data)
            limitsSection(details, data: data)
            requestsSection(details, data: data)
            alertsSection(details, data: data)
            aboutSection(details, data: data)
            if model.isParent, let kid = model.data.kids[item.kidID] {
                Section {
                    NavigationLink { PolicyView(kid: kid) } label: { Label("Edit Screen Time", systemImage: "hourglass") }
                }
            }
        }
        .navigationTitle(AppCatalog.shared.name(of: shown, in: data.items) ?? item.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .bugButton()
        .task { if model.isKid { kidData = .kid() } }
        .refreshable {
            if model.isKid { kidData = .kid() } else { await model.refresh() }
        }
    }

    // MARK: - Use

    @ViewBuilder
    private func usageSection(_ usage: AppDetails.Usage, details: AppDetails, data: AppDetailsData, name: String?) -> some View {
        Section {
            LabeledContent("Today", value: Self.time(usage.today))
            LabeledContent("Yesterday", value: Self.time(usage.yesterday))
            LabeledContent("Last 7 days", value: Self.time(usage.last7Days))
            LabeledContent("Last 30 days", value: Self.time(usage.last30Days))
            LabeledContent("Daily average", value: usage.dailyAverage.map(Self.time) ?? "—")
            if let last = usage.lastUsed {
                LabeledContent("Last used", value: Calendar.current.isDateInToday(last) ? Format.time(last)
                               : last.formatted(date: .abbreviated, time: .shortened))
            }
            if usage.last30Days > 0 {
                Chart(usage.days, id: \.day) { day in
                    BarMark(x: .value("Day", day.day.start(), unit: .day), y: .value("Minutes", day.seconds / 60))
                        .foregroundStyle(day.day == usage.days.last?.day ? Color.accentColor : Color.accentColor.opacity(0.55))
                    if let average = usage.dailyAverage {
                        RuleMark(y: .value("Average", average / 60))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundStyle(.secondary)
                    }
                }
                .chartYAxisLabel("min")
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .frame(height: 140)
                .padding(.vertical, 4)
            }
            NavigationLink {
                // Opens on the last day it was used: today's raw list is empty when it wasn't used today.
                RawUsageView(items: data.items, samples: { data.samples($0).filter { details.ids.contains($0.itemID) } },
                             day: usage.lastUsed.map { DayKey($0) } ?? DayKey(Date()), only: name ?? item.displayName)
            } label: {
                Label("Raw usage", systemImage: "list.bullet.rectangle")
            }
        } header: {
            Text("Use")
        } footer: {
            Text(usage.reportedDays == 0 ? "Apple's count. No earlier days reported yet."
                 : "Apple's count. The average is over the \(usage.reportedDays) days before today the phone reported use, out of the last 30.")
        }
    }

    // MARK: - Policy

    @ViewBuilder
    private func groupsSection(_ details: AppDetails, data: AppDetailsData) -> some View {
        Section {
            ForEach(details.groups) { group in
                LabeledContent {
                    Text(Self.describe(details.via(group), details: details, data: data) ?? "")
                } label: {
                    GroupName(group: group)
                }
            }
            if !details.alwaysAllowed.isEmpty {
                listRow("Always Allowed", systemImage: "checkmark.circle", via: details.alwaysAllowed, details, data)
            } else if details.isExempt {
                Label("Always allowed: ScreenThyme and Phone never block it", systemImage: "checkmark.circle")
            }
            if !details.blocked.isEmpty {
                listRow("Blocked", systemImage: "nosign", via: details.blocked, details, data)
            }
            if details.groups.isEmpty && details.alwaysAllowed.isEmpty && details.blocked.isEmpty && !details.isExempt {
                Text("Not in any group, Always Allowed or Blocked.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Groups")
        } footer: {
            if !details.blocked.isEmpty { Text("Blocked apps never open.") }
        }
    }

    private func listRow(_ title: String, systemImage: String, via: [AppDetails.Via], _ details: AppDetails,
                         _ data: AppDetailsData) -> some View {
        LabeledContent {
            Text(Self.describe(via, details: details, data: data) ?? "")
        } label: {
            Label(title, systemImage: systemImage)
        }
    }

    @ViewBuilder
    private func downtimeSection(_ details: AppDetails, data: AppDetailsData) -> some View {
        Section {
            ForEach(details.downtime, id: \.window.id) { entry in
                LabeledContent {
                    Text(entry.window.schedule())
                } label: {
                    Text(entry.window.name)
                    Text(entry.via == [.everything] ? "Whole phone" : Self.describe(entry.via, details: details, data: data) ?? "This app")
                }
            }
            if details.downtime.isEmpty {
                Text(details.isAlwaysAllowed ? "Always allowed, so Downtime doesn't block it." : "No Downtime covers it.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Downtime")
        } footer: {
            if details.isAlwaysAllowed && !details.downtime.isEmpty {
                Text("Always allowed, so these don't block it.")
            }
        }
    }

    /// "+ 1 h 0 min for this app": what parents gave today on `limit` for this app (or its category) alone.
    static func givenToApp(_ limit: AppLimit, details: AppDetails, grants: [TimeGrant]) -> String? {
        let given = grants.filter { grant in
            grant.approved && grant.reason == .limit(limit.id) && Calendar.current.isDateInToday(grant.at)
                && grant.itemID.map { details.ids.contains($0) || details.categoryIDs.contains($0) } == true
        }
        guard !given.isEmpty else { return nil }
        if given.contains(where: { $0.minutes == nil }) { return "No limit for this app today" }
        return "+ \(Format.minutes(given.reduce(0) { $0 + ($1.minutes ?? 0) })) for this app"
    }

    @ViewBuilder
    private func limitsSection(_ details: AppDetails, data: AppDetailsData) -> some View {
        let weekday = Calendar.current.component(.weekday, from: Date())
        Section {
            ForEach(details.limits, id: \.limit.id) { entry in
                let limit = entry.limit
                LabeledContent {
                    if !limit.enabled {
                        Text("Off")
                    } else if let used = data.plan?.used[limit.id] {
                        let budget = data.plan?.budgets[limit.id]
                        let extra = budget.map { $0 - limit.minutes(on: weekday) }
                        VStack(alignment: .trailing) {
                            Text(budget.map { "\(Format.minutes(used)) of \(Format.minutes($0))" } ?? "\(Format.minutes(used)), no limit today")
                                .foregroundStyle(budget.map { used >= $0 } == true ? Color.orange : Color.secondary)
                            if budget == nil || extra.map({ $0 > 0 }) == true {
                                Text(extra.map { "\(Format.minutes(limit.minutes(on: weekday))) + \(Format.minutes($0)) extra" }
                                     ?? "A parent gave the rest of today")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            if let given = Self.givenToApp(limit, details: details, grants: data.grants) {
                                Text(given).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("\(Format.minutes(limit.minutes(on: weekday))) a day")
                    }
                } label: {
                    Text(limit.name)
                    Text(entry.via == [.everything] ? "All apps and websites" : Self.describe(entry.via, details: details, data: data) ?? "This app")
                }
            }
            if details.limits.isEmpty {
                Text(details.isAlwaysAllowed ? "Always allowed, so limits don't count it." : "No limit counts it.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Limits")
        } footer: {
            if !details.limits.isEmpty {
                Text(details.isAlwaysAllowed ? "Always allowed, so these don't count it or block it."
                     : "Used today across everything each limit counts, out of the limit plus any extra time a parent gave today. Time a parent gave for one app lets only that app through. Always Allowed apps, ScreenThyme and Phone don't count.")
            }
        }
    }

    // MARK: - Requests and alerts

    @ViewBuilder
    private func requestsSection(_ details: AppDetails, data: AppDetailsData) -> some View {
        let since = Calendar.current.date(byAdding: .day, value: -AppDetails.usageDays, to: Date())!
        let requests = details.requests(data.requests, grants: data.grants, extraMinutes: data.extraMinutes, since: since)
        Section {
            ForEach(requests.prefix(20)) { RequestHistoryRow(request: $0, details: details, data: data) }
            if requests.isEmpty {
                Text("No requests in the last 30 days.").foregroundStyle(.secondary)
            }
        } header: {
            Text("More time")
        } footer: {
            Text("Asking a parent (or self-approving, when no parent answers), and One more minute on the block page, for this app or its category, for more time on a limit that counts it, or for the whole phone.")
        }
    }

    @ViewBuilder
    private func alertsSection(_ details: AppDetails, data: AppDetailsData) -> some View {
        let rules = details.alertRules(data.rules)
        let since = Calendar.current.date(byAdding: .day, value: -AppDetails.usageDays, to: Date())!
        let alerts = data.alerts.filter { $0.ruleID != nil && $0.at >= since && $0.itemID.map(details.ids.contains) == true }
            .sorted { $0.at > $1.at }
        if !rules.isEmpty || !alerts.isEmpty {
            Section("Alerts") {
                ForEach(rules) { rule in
                    if case let .dailyThreshold(_, minutes) = rule.condition {
                        LabeledContent("Alert over \(Format.minutes(minutes)) a day", value: rule.enabled ? "On" : "Off")
                    }
                }
                ForEach(alerts.prefix(5)) { alert in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(alert.title)
                        Text(alert.at.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - About

    @ViewBuilder
    private func aboutSection(_ details: AppDetails, data: AppDetailsData) -> some View {
        Section("About") {
            LabeledContent("Kind", value: item.kind.title)
            if let usageItem = details.usageItem {
                LabeledContent(usageItem.kind == .domain ? "Website" : "Bundle ID") {
                    Text(usageItem.identifier).textSelection(.enabled)
                }
            }
            if let category = details.categoryName {
                LabeledContent("Category", value: category)
            }
            let firstSeen = details.ids.compactMap { data.items[$0]?.firstSeen }.min() ?? item.firstSeen
            LabeledContent("First seen", value: firstSeen.formatted(date: .abbreviated, time: .omitted))
            LabeledContent("Matched to app scan", value: details.tokenItem != nil && details.usageItem != nil ? "Yes" : "No")
        }
    }

    // MARK: - Text

    static func time(_ seconds: Double) -> String {
        Format.minutes(Int((seconds / 60).rounded()))
    }

    /// "Through Games", "Through Fun and Games"; nil when it names the app itself only.
    static func describe(_ via: [AppDetails.Via], details: AppDetails, data: AppDetailsData) -> String? {
        let names = via.compactMap { via -> String? in
            switch via {
            case .item: nil
            case let .group(id): data.policy.groups.first { $0.id == id }?.name
            case let .category(id): data.items[id].map { categoryName($0, in: data.items) }
            case .everything: "everything"
            }
        }
        guard !names.isEmpty else { return nil }
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        return via.contains(.item) ? "Itself and through \(list)" : "Through \(list)"
    }
}


/// A row that opens an app's or website's details; categories have none.
struct ItemDetailsLink<Content: View>: View {
    let item: TrackedItem?
    @ViewBuilder var label: Content

    var body: some View {
        if let item, item.kind != .category {
            NavigationLink { AppDetailsView(item: item) } label: { label }
        } else {
            label
        }
    }
}

/// A category's name: a scanned one goes by its match's, from Apple's data.
private func categoryName(_ category: TrackedItem, in items: [UUID: TrackedItem]) -> String {
    if category.nickname == nil, let match = category.match.flatMap({ items[$0] }) { return match.displayName }
    return category.displayName
}

private struct StatusRow: View {
    let status: AppDetails.Status?
    let hasPolicy: Bool

    var body: some View {
        switch status {
        case nil, .notEnforced?:
            Label(hasPolicy ? "Screen Time is off" : "No Screen Time limits", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        case .open?:
            Label("Open now", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case let .downtime(name, until)?:
            Label("\(name) until \(Format.time(until))", systemImage: "moon.fill").foregroundStyle(.indigo)
        case let .limit(name)?:
            Label("Over the \(name) limit today", systemImage: "hourglass.bottomhalf.filled").foregroundStyle(.orange)
        case .blocked?:
            Label("Blocked", systemImage: "nosign").foregroundStyle(.red)
        }
    }
}

/// An hourglass in a list of apps for one Downtime or a limit shields (now, or for a limit, on an earlier day);
/// nothing otherwise.
struct TimeShieldIcon: View {
    let status: AppDetails.Status?

    var body: some View {
        switch status {
        case let .downtime(name, until)?:
            Image(systemName: "hourglass").foregroundStyle(.indigo)
                .accessibilityLabel("\(name) until \(Format.time(until))")
        case let .limit(name)?:
            Image(systemName: "hourglass").foregroundStyle(.orange)
                .accessibilityLabel("Over the \(name) limit")
        default:
            EmptyView()
        }
    }
}

/// A request for more time, with its answer, or a one more minute.
private struct RequestHistoryRow: View {
    let request: AppDetails.Request
    let details: AppDetails
    let data: AppDetailsData

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch request {
            case let .asked(asked, grant):
                Label {
                    Text(asked.reason == .alwaysAllow ? "Asked to always allow it"
                        : "Asked for \(ShieldContext.describe(minutes: asked.minutes)) \(reason(asked.reason, asked.itemID))")
                } icon: {
                    if grant?.isSelfApproved == true {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else {
                        Image(systemName: grant == nil ? "hourglass" : grant!.approved ? "checkmark.circle" : "xmark.circle")
                            .foregroundStyle(grant == nil ? Color.secondary : grant!.approved ? Color.green : Color.red)
                    }
                }
                otherItem(asked.itemID)
                if let note = asked.note { Text("\u{201C}\(note)\u{201D}").italic().font(.subheadline) }
                Text(answer(grant)).font(.subheadline)
                    .foregroundStyle(grant?.isSelfApproved == true ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                if let reason = grant?.selfApproval {
                    Text("Why: \u{201C}\(reason)\u{201D}").italic().font(.subheadline)
                }
                if let grant, let ended = grant.endedAt {
                    Text("\(grant.endedBy ?? "A parent") ended it early at \(ended.formatted(date: .omitted, time: .shortened))")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else if let grant, data.canEnd, grant.mightBeRunning(at: Date()) {
                    EndGrantButton(grant: grant)
                }
            case let .extraMinute(use):
                Label {
                    Text("\(ShieldContext.MoreTime.oneMoreMinute.title(minutes: use.minutes)) \(reason(use.reason, use.itemID))")
                } icon: {
                    Image(systemName: "timer").foregroundStyle(.tint)
                }
                otherItem(use.itemID)
            }
            Text(request.at.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
        }
        .listRowBackground(isSelfApproved ? SelfApproval.background : nil)
    }

    private var isSelfApproved: Bool {
        guard case let .asked(_, grant) = request else { return false }
        return grant?.isSelfApproved == true
    }

    /// The app the kid asked from, when it's another one that shares a limit.
    @ViewBuilder
    private func otherItem(_ itemID: UUID?) -> some View {
        if let itemID, !details.ids.contains(itemID), !details.categoryIDs.contains(itemID), let item = data.items[itemID] {
            HStack(spacing: 4) {
                Text("From")
                ItemName(item: item)
            }
            .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    /// "over the Games limit", with "for Games" when the request named the category.
    private func reason(_ reason: BlockReason, _ itemID: UUID?) -> String {
        let text = RequestRow.describe(reason, itemID: itemID, policy: data.policy)
        guard let itemID, details.categoryIDs.contains(itemID), let category = data.items[itemID] else { return text }
        return "for \(categoryName(category, in: data.items)) \(text)"
    }

    private func answer(_ grant: TimeGrant?) -> String {
        guard let grant else { return "Waiting for an answer" }
        let when = grant.at.formatted(date: .omitted, time: .shortened)
        if grant.reason == .alwaysAllow {
            return grant.approved ? "\(grant.by) allowed it always at \(when)" : "\(grant.by) said no at \(when)"
        }
        if grant.isSelfApproved {
            return "Self-approved by \(grant.by) at \(when), with no parent's answer"
        }
        return grant.approved ? "\(grant.by) gave \(ShieldContext.describe(minutes: grant.minutes)) at \(when)"
            : "\(grant.by) said no at \(when)"
    }
}

/// What the details are made from: a parent's mirror of the family zone, or the kid's own App Group.
struct AppDetailsData {
    /// A parent's phone: running approvals can be ended from the details.
    var canEnd = false
    var items: [UUID: TrackedItem] = [:]
    var policy: Policy
    var hasPolicy = false
    /// What's blocked now: the kid phone's applied plan, or on a parent's phone, worked out from what has synced.
    var plan: EnforcementPlan?
    var samples: (DayKey) -> [UsageSample] = { _ in [] }
    var requests: [TimeRequest] = []
    var grants: [TimeGrant] = []
    var extraMinutes: [ExtraMinuteUse] = []
    var rules: [Rule] = []
    var alerts: [AlertRecord] = []

    static var empty: AppDetailsData { AppDetailsData(policy: Policy(kidID: UUID(), enabled: false)) }

    @MainActor
    static func parent(_ family: FamilyData, kid: UUID, now: Date = Date()) -> AppDetailsData {
        let items = family.items(for: kid)
        let policy = family.policy(for: kid)
        let uses = family.extraMinutes.values.filter { $0.kidID == kid }
        let plan = parentPlan(family, kid: kid, items: items, policy: policy, now: now)
        return AppDetailsData(canEnd: true, items: items, policy: policy, hasPolicy: family.storedPolicy(for: kid) != nil, plan: plan,
                              samples: { family.samples(kid: kid, day: $0) },
                              requests: family.requests.values.filter { $0.kidID == kid },
                              grants: family.grants.values.filter { $0.kidID == kid }, extraMinutes: Array(uses),
                              rules: family.rules(for: kid), alerts: family.alerts.values.filter { $0.kidID == kid })
    }

    /// What's blocked now on a kid's phone, worked out on a parent's phone from what has synced.
    @MainActor
    static func parentPlan(_ family: FamilyData, kid: UUID, items: [UUID: TrackedItem], policy: Policy,
                           now: Date = Date()) -> EnforcementPlan {
        let today = DayKey(now)
        // Today's answers and one more minutes, as the kid's phone applied them (about when they were given).
        var state = EnforcementDayState(day: today)
        let samples = family.samples(kid: kid, day: today)
        state.grants = family.grants.values.filter { $0.kidID == kid && DayKey($0.at) == today }
            .sorted { $0.at < $1.at }.map { grant in
                // The app's use before the answer, which the grant's minutes come after.
                let before = AppDetails.usage(samples.filter { $0.end <= grant.at }, items: items)
                return AppliedGrant(grant: grant, appliedAt: grant.at, baselineSeconds: grant.itemID.flatMap { before[$0] } ?? 0)
            }
        state.extraMinutes = family.extraMinutes.values.filter { $0.kidID == kid && DayKey($0.at) == today }
            .map { ExtraMinute(itemID: $0.itemID, reason: $0.reason, at: $0.at, minutes: $0.minutes) }
        let usage = AppDetails.usage(samples, items: items)
        let mirrored = family.webMirrored(kid: kid, items: items, today: today)
        return EnforcementPlanner.plan(policy: policy, items: items, usage: usage, state: state, now: now,
                                       exempt: Enforcer.exemptItems(items).union(mirrored))
    }

    static func kid() -> AppDetailsData {
        let items = Dictionary(AppGroup.loadItems().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let stored = AppGroup.loadPolicy()?.followingNewTokens(items: items)
        let samples = Dictionary(grouping: AppGroup.samples.readAll(), by: \.day)
        // The latest copy of each: a parent's end follows the answer.
        var grants = Dictionary(AppGroup.grantHistory.readAll().map { ($0.requestID, $0) }, uniquingKeysWith: { _, b in b })
        // Answers applied before the history file existed are still in today's state.
        for applied in Enforcer.loadState().grants { grants[applied.grant.requestID] = applied.grant }
        let config = SharedConfig.load()
        return AppDetailsData(items: items, policy: stored ?? Policy(kidID: config.kid?.id ?? UUID(), enabled: false),
                              hasPolicy: stored != nil, plan: Enforcer.loadApplied()?.plan,
                              samples: { samples[$0] ?? [] }, requests: AppGroup.requests.readAll(),
                              grants: Array(grants.values), extraMinutes: AppGroup.extraMinuteUses.readAll(),
                              rules: config.currentRules, alerts: AppGroup.outbox.readAll())
    }
}
