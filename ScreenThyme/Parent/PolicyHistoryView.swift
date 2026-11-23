import SwiftUI
import ThymeCore

/// Everything that changed what a kid's phone enforces, oldest first: each parent's saves of the policy (Downtime,
/// limits, Always Allowed, blocked apps, Content & Privacy), temporary ones changing back (those still to come last,
/// as scheduled) and their answers to requests for more time, with the kid's own approvals marked.
struct PolicyHistoryView: View {
    @Environment(AppModel.self) private var model
    let kid: Kid

    var body: some View {
        let entries = model.data.policyHistory(for: kid.id)
        let days = Dictionary(grouping: entries) { Calendar.current.startOfDay(for: $0.at) }
        // Opens on the latest change.
        ScrollViewReader { proxy in
            List {
                ForEach(days.keys.sorted(), id: \.self) { day in
                    let title = day.formatted(date: .complete, time: .omitted)
                    Section(day > Date() ? "\(title) · Coming up" : title) {
                        ForEach(days[day] ?? []) { PolicyHistoryRow(entry: $0, kid: kid) }
                    }
                }
            }
            .onAppear { if let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) } }
        }
        .navigationTitle("Change history")
        .bugButton()
        .refreshable { await model.refresh() }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("No changes yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("Each saved change to \(kid.displayName)'s Screen Time, when a temporary one changes back, and each answer to a request for more time, shows here with who made it."))
            }
        }
    }
}

struct PolicyHistoryRow: View {
    @Environment(AppModel.self) private var model
    let entry: PolicyHistoryEntry
    let kid: Kid

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(header, systemImage: icon).font(.subheadline.bold())
                    .foregroundStyle(isSelfApproved ? .orange : .primary)
                Spacer()
                Text(Format.time(entry.at)).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.title)
                    ForEach(line.details, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
            }
            switch entry {
            case let .change(change):
                if let until = change.until {
                    Label("Temporary: \(Self.days(from: change.at, to: until)), changes back \(Self.end(until))",
                          systemImage: "timer")
                        .font(.caption).foregroundStyle(.orange)
                }
            case let .revert(revert):
                Text("Ends \(revert.change.by)'s change of \(revert.change.at.formatted(.dateTime.weekday(.abbreviated).month().day())), made for \(Self.days(from: revert.change.at, to: revert.at)).")
                    .font(.caption).foregroundStyle(.secondary)
            case let .grant(grant):
                if let reason = grant.selfApproval {
                    Text("Why: \u{201C}\(reason)\u{201D}").italic().font(.subheadline)
                    Label("No parent answered: \(grant.by) approved this without a parent", systemImage: "person.fill.questionmark")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let ended = grant.endedAt {
                    Label("Ended early by \(grant.endedBy ?? "a parent") at \(Format.time(ended))", systemImage: "stop.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(isSelfApproved ? SelfApproval.background : nil)
    }

    private var isSelfApproved: Bool {
        guard case let .grant(grant) = entry else { return false }
        return grant.isSelfApproved
    }

    private var header: String {
        if isSelfApproved { return "\(entry.by) · self-approved" }
        guard case let .revert(revert) = entry else { return entry.by }
        return revert.at > Date() ? "Scheduled: changes back" : "Changed back"
    }

    private var icon: String {
        switch entry {
        case .change: "slider.horizontal.3"
        case let .revert(revert): revert.at > Date() ? "calendar.badge.clock" : "arrow.uturn.backward.circle"
        case let .grant(grant): grant.isSelfApproved ? "exclamationmark.triangle.fill" : grant.approved ? "checkmark.circle" : "xmark.circle"
        }
    }

    /// "1 day" or "3 days": the days a temporary change lasts, counting the day it was made.
    static func days(from start: Date, to until: Date) -> String {
        let calendar = Calendar.current
        let days = max(1, calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: until).day ?? 1)
        return days == 1 ? "1 day" : "\(days) days"
    }

    /// "at the end of today" or "at the end of Tuesday, Nov 24": the day before the midnight a temporary change ends.
    static func end(_ until: Date) -> String {
        let last = until.addingTimeInterval(-1)
        if Calendar.current.isDateInToday(last) { return "at the end of today" }
        return "at the end of \(last.formatted(.dateTime.weekday(.wide).month().day()))"
    }

    /// Names items as matched apps and groups by `groups`; for edits and answers.
    static func namer(groups: [ItemGroup], items: [UUID: TrackedItem]) -> (UUID) -> String {
        { id in
            if let group = groups.first(where: { $0.id == id }) { return "group \u{201C}\(group.name)\u{201D}" }
            guard let item = items[id] else { return "a removed item" }
            return AppCatalog.shared.name(of: item, in: items) ?? item.displayName
        }
    }

    private var lines: [(title: String, details: [String])] {
        let items = model.data.items(for: kid.id)
        // Groups by their names before or after the change (or now, for a grant).
        let groups: [ItemGroup] = switch entry {
        case let .change(change): change.after.groups + (change.before?.groups ?? [])
        case let .revert(revert): revert.change.after.groups + (revert.change.before?.groups ?? [])
            + model.data.policy(for: kid.id).groups
        case .grant: model.data.policy(for: kid.id).groups
        }
        let name = Self.namer(groups: groups, items: items)
        switch entry {
        case let .change(change):
            return change.edits.map { $0.describe(name: name) }
        case let .revert(revert):
            return revert.edits.map { $0.describe(name: name) }
        case let .grant(grant):
            if grant.reason == .alwaysAllow {
                let what = grant.itemID.map(name) ?? "an app"
                return [(grant.approved ? "Always allowed \(what), as asked" : "Said no to always allowing \(what)", [])]
            }
            let what = grant.itemID.map { " for \(name($0))" } ?? ""
            let reason = RequestRow.describe(grant.reason, itemID: grant.itemID, policy: model.data.policy(for: kid.id))
            let title = grant.isSelfApproved ? "Took \(ShieldContext.describe(minutes: grant.minutes))\(what) \(reason)"
                : grant.approved ? "Gave \(ShieldContext.describe(minutes: grant.minutes))\(what) \(reason)"
                : "Said no to more time\(what) \(reason)"
            return [(title, [])]
        }
    }
}
