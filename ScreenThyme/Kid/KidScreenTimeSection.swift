import SwiftUI
import ThymeCore

/// What ScreenThyme enforces right now and the kid's requests for more time (PLAN.md §15). While a request waits,
/// the app uploads it and checks for the answer every few seconds.
struct KidScreenTimeSection: View {
    @Environment(AppModel.self) private var model
    @State private var applied = Enforcer.loadApplied()
    @State private var requests = KidSync.openRequests()
    @State private var answers: [AppliedGrant] = Enforcer.loadState().grants
    @State private var asking = false

    var body: some View {
        let items = Dictionary(AppGroup.loadItems().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        Section("Screen Time") {
            if let plan = applied?.plan, let policy = AppGroup.loadPolicy(), policy.enabled {
                if let downtime = plan.downtime {
                    LabeledContent(downtime.name, value: "until \(Format.time(downtime.interval.end))")
                }
                ForEach(policy.limits.filter(\.enabled)) { limit in
                    let used = plan.used[limit.id] ?? 0
                    LabeledContent(limit.name, value: plan.budgets[limit.id].map { "\(Format.minutes(used)) of \(Format.minutes($0))" }
                        ?? "no limit today")
                }
                if plan.downtime == nil && policy.limits.isEmpty {
                    Text("No Downtime now and no limits.").foregroundStyle(.secondary)
                }
                itemList("Always Allowed", ids: policy.alwaysAllowed, items: items,
                         footer: "These work during Downtime and don't count toward limits. ScreenThyme and Phone are always allowed too.")
                itemList("Blocked", ids: policy.blocked, items: items, footer: "These never open.")
            } else {
                Text("No limits on this phone.").foregroundStyle(.secondary)
            }
            if let plan = applied?.plan, plan.downtime != nil || !plan.exhaustedLimits.isEmpty || !plan.blockedItems.isEmpty {
                Button("Ask for more time") { asking = true }
            }
            ForEach(requests) { request in
                Label("Asked for \(ShieldContext.describe(minutes: request.minutes)) of \(request.itemID.flatMap { items[$0]?.displayName } ?? "an app") · waiting",
                      systemImage: "hourglass")
            }
            ForEach(answers.suffix(3).reversed(), id: \.grant.requestID) { answer in
                let name = answer.grant.itemID.flatMap { items[$0]?.displayName } ?? "an app"
                if answer.grant.approved {
                    Label("\(answer.grant.by) gave \(ShieldContext.describe(minutes: answer.grant.minutes)) of \(name)",
                          systemImage: "checkmark.circle").foregroundStyle(.green)
                } else {
                    Label("\(answer.grant.by) said no to more time for \(name)", systemImage: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .sheet(isPresented: $asking, onDismiss: reload) { AskForTimeView() }
        .task(id: requests.map(\.id)) {
            reload()
            while !requests.isEmpty, !Task.isCancelled {
                await model.flush()
                await KidSync.refreshIfDue(config: model.config)
                reload()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    @ViewBuilder
    private func itemList(_ title: String, ids: Set<UUID>, items: [UUID: TrackedItem], footer: String) -> some View {
        if ids.isEmpty {
            LabeledContent(title, value: "none")
        } else {
            NavigationLink {
                SelectedItemsView(title: title, ids: ids, items: items, footer: footer)
            } label: {
                LabeledContent(title, value: "\(ids.count)")
            }
        }
    }

    private func reload() {
        applied = Enforcer.loadApplied()
        requests = KidSync.openRequests()
        answers = Enforcer.loadState().grants
    }
}

