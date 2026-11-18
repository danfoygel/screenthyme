import SwiftUI
import ThymeCore

/// Everything that changed what a kid's phone enforces, oldest first: each parent's saves of the policy (Downtime,
/// limits, Always Allowed, blocked apps, Content & Privacy) and their answers to requests for more time.
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
                    Section(day.formatted(date: .complete, time: .omitted)) {
                        ForEach(days[day] ?? []) { PolicyHistoryRow(entry: $0, kid: kid) }
                    }
                }
            }
            .onAppear { if let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) } }
        }
        .navigationTitle("Change history")
        .refreshable { await model.refresh() }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("No changes yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("Each saved change to \(kid.displayName)'s Screen Time, and each answer to a request for more time, shows here with who made it."))
            }
        }
    }
}

private struct PolicyHistoryRow: View {
    @Environment(AppModel.self) private var model
    let entry: PolicyHistoryEntry
    let kid: Kid

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(entry.by, systemImage: icon).font(.subheadline.bold())
                Spacer()
                Text(Format.time(entry.at)).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.title)
                    ForEach(line.details, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch entry {
        case .change: "slider.horizontal.3"
        case let .grant(grant): grant.approved ? "checkmark.circle" : "xmark.circle"
        }
    }

    private var lines: [(title: String, details: [String])] {
        let items = model.data.items(for: kid.id)
        // Groups by their names before or after the change (or now, for a grant).
        let groups: [ItemGroup] = switch entry {
        case let .change(change): change.after.groups + (change.before?.groups ?? [])
        case .grant: model.data.policy(for: kid.id).groups
        }
        func name(_ id: UUID) -> String {
            if let group = groups.first(where: { $0.id == id }) { return "group \u{201C}\(group.name)\u{201D}" }
            guard let item = items[id] else { return "a removed item" }
            return AppCatalog.shared.name(of: item, in: items) ?? item.displayName
        }
        switch entry {
        case let .change(change):
            return change.edits.map { $0.describe(name: name) }
        case let .grant(grant):
            let what = grant.itemID.map { " for \(name($0))" } ?? ""
            let reason = RequestRow.describe(grant.reason, itemID: grant.itemID, policy: model.data.policy(for: kid.id))
            let title = grant.approved ? "Gave \(ShieldContext.describe(minutes: grant.minutes))\(what) \(reason)"
                : "Said no to more time\(what) \(reason)"
            return [(title, [])]
        }
    }
}
