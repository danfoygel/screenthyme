import SwiftUI
import ThymeCore

/// What ScreenThyme enforces right now and the kid's requests for more time or to always allow an app (PLAN.md §15). While a request waits,
/// the app uploads it and checks for the answer every few seconds.
struct KidScreenTimeSection: View {
    @Environment(AppModel.self) private var model
    @State private var applied = Enforcer.loadApplied()
    @State private var requests = KidSync.openRequests()
    @State private var answers: [AppliedGrant] = Enforcer.loadState().grants
    @State private var asking = false
    @State private var askingAlwaysAllow = false

    var body: some View {
        let items = Dictionary(AppGroup.loadItems().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        Section("Screen Time") {
            if let plan = applied?.plan, let policy = AppGroup.loadPolicy()?.resolved(items: items), policy.enabled {
                if let downtime = plan.downtime {
                    LabeledContent(downtime.name, value: "until \(Format.time(downtime.interval.end))")
                }
                ForEach(plan.scopedDowntime, id: \.windowID) { downtime in
                    NavigationLink {
                        SelectedItemsView(title: downtime.name, ids: downtime.items, items: items,
                                          footer: "These are off until \(Format.time(downtime.interval.end)).")
                    } label: {
                        LabeledContent(downtime.name, value: "\(downtime.items.count) off until \(Format.time(downtime.interval.end))")
                    }
                }
                ForEach(policy.limits.filter(\.enabled)) { limit in
                    let used = plan.used[limit.id] ?? 0
                    LabeledContent(limit.name, value: plan.budgets[limit.id].map { "\(Format.minutes(used)) of \(Format.minutes($0))" }
                        ?? "no limit today")
                }
                if !plan.hasDowntime && policy.limits.isEmpty {
                    Text("No Downtime now and no limits.").foregroundStyle(.secondary)
                }
                itemList("Always Allowed", ids: policy.alwaysAllowed, items: items,
                         footer: "These work during Downtime and don't count toward limits. ScreenThyme and Phone are always allowed too.")
                if !policy.uncounted.isEmpty {
                    itemList("Uncounted", ids: policy.uncounted, items: items,
                             footer: "Always allowed, and their time isn't added to your total for the day.")
                }
                itemList("Blocked", ids: policy.blocked, items: items, footer: "These never open.")
            } else {
                Text("No limits on this phone.").foregroundStyle(.secondary)
            }
            if let plan = applied?.plan, plan.hasDowntime || !plan.exhaustedLimits.isEmpty || !plan.blockedItems.isEmpty {
                Button("Ask for more time") { asking = true }
            }
            if applied?.plan != nil, AppGroup.loadPolicy()?.enabled == true {
                Button("Ask to always allow an app") { askingAlwaysAllow = true }
            }
            ForEach(requests) { request in
                let name = request.itemID.flatMap { items[$0] }.map { AppCatalog.shared.name(of: $0, in: items) ?? $0.displayName } ?? "an app"
                if request.reason == .alwaysAllow {
                    Label("Asked to always allow \(name) · waiting", systemImage: "hourglass")
                } else {
                    Label("Asked for \(ShieldContext.describe(minutes: request.minutes)) of \(name) · waiting",
                          systemImage: "hourglass")
                    if request.canSelfApprove {
                        SelfApproveRow(request: request, done: reload)
                    }
                }
            }
            ForEach(answers.suffix(3).reversed(), id: \.grant.requestID) { answer in
                let name = answer.grant.itemID.flatMap { items[$0] }.map { AppCatalog.shared.name(of: $0, in: items) ?? $0.displayName } ?? "an app"
                if answer.grant.reason == .alwaysAllow {
                    if answer.grant.approved {
                        Label("\(answer.grant.by) always allowed \(name)", systemImage: "checkmark.circle").foregroundStyle(.green)
                    } else {
                        Label("\(answer.grant.by) said no to always allowing \(name)", systemImage: "xmark.circle")
                            .foregroundStyle(.secondary)
                    }
                } else if answer.grant.isSelfApproved {
                    Label("You approved \(ShieldContext.describe(minutes: answer.grant.minutes)) of \(name) yourself",
                          systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else if answer.grant.approved {
                    Label("\(answer.grant.by) gave \(ShieldContext.describe(minutes: answer.grant.minutes)) of \(name)",
                          systemImage: "checkmark.circle").foregroundStyle(.green)
                } else {
                    Label("\(answer.grant.by) said no to more time for \(name)", systemImage: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
                if let ended = answer.grant.endedAt {
                    Label("\(answer.grant.endedBy ?? "A parent") ended it early at \(Format.time(ended))", systemImage: "stop.circle")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .sheet(isPresented: $asking, onDismiss: reload) { AskForTimeView() }
        .sheet(isPresented: $askingAlwaysAllow, onDismiss: reload) { AskAlwaysAllowView() }
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

