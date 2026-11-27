import SwiftUI
import ThymeCore

/// The kid approves their own request for more time, when no parent can answer (PLAN.md §15.11): for what they asked,
/// with a reason. The parents are alerted at once, and their phones mark it everywhere it shows.
struct SelfApproveView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: TimeRequest
    var approved: (TimeGrant) -> Void = { _ in }
    @State private var reason = ""
    @State private var confirming = false
    @State private var answered = false

    var body: some View {
        let context = ShieldContext()
        let items = Dictionary(context.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let name = request.itemID.flatMap { items[$0] }.flatMap { AppCatalog.shared.name(of: $0, in: items) }
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        NavigationStack {
            Form {
                Section {
                    Label("Emergencies only", systemImage: "exclamationmark.octagon.fill")
                        .font(.headline)
                        .foregroundStyle(.red)
                    Text("Use this only if you really need this right now and no parent can answer: they don't pick up or text back, or there's no signal to reach them.")
                    Text("Being bored, wanting to keep playing, or thinking they'd say no is **not** an emergency. Neither is not wanting to wait.")
                    Text("Your parents get an alert right away. Their phones mark it as self-approved, with your reason, in their alerts, change history and this app's details, and they can see everything you use with this time. Expect to explain it.")
                }
                .listRowBackground(Color.red.opacity(0.08))
                Section("You'd be approving") {
                    Text(context.describe(request, name: name))
                }
                Section {
                    TextField("Why can't this wait for a parent?", text: $reason, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    Text("Your reason")
                } footer: {
                    Text("Required. Your parents will read it.")
                }
                Section {
                    Button("Approve it myself", role: .destructive) { confirming = true }
                        .disabled(reason.count < TimeGrant.minimumSelfApprovalReason)
                }
            }
            .navigationTitle("Approve it yourself")
            .bugButton(help: .selfApprove)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .alert("Is this really an emergency?", isPresented: $confirming) {
                Button("Yes, approve it", role: .destructive) { approve(name: name, reason: reason) }
                Button("No, wait for a parent", role: .cancel) {}
            } message: {
                Text("Your parents will be told now that you approved it yourself, and why.")
            }
            .alert("Already answered", isPresented: $answered) {
                Button("OK") { dismiss() }
            } message: {
                Text("A parent already answered this request.")
            }
        }
    }

    private func approve(name: String?, reason: String) {
        let request = request
        Task {
            let grant = await Task.detached(priority: .userInitiated) {
                ShieldContext().selfApprove(request, name: name, because: reason)
            }.value
            guard let grant else {
                answered = true
                return
            }
            model.nearby.sendUpdates()
            approved(grant)
            dismiss()
            await model.flush()
        }
    }
}

/// Offered under a request that's waiting for an answer.
struct SelfApproveButton: View {
    let action: () -> Void

    var body: some View {
        Section {
            Button("Approve it myself\u{2026}", role: .destructive, action: action)
        } header: {
            Text("Can't reach a parent?")
        } footer: {
            Text("Emergencies only. Your parents are alerted right away.")
        }
    }
}

/// Under a waiting request in a list: its own row, so its sheet isn't spread over the section's rows.
struct SelfApproveRow: View {
    let request: TimeRequest
    var done: () -> Void = {}
    @State private var approving = false

    var body: some View {
        Button("Can't reach a parent? Approve it myself\u{2026}", role: .destructive) { approving = true }
            .font(.subheadline)
            .sheet(isPresented: $approving, onDismiss: done) { SelfApproveView(request: request) }
    }
}

extension ShieldContext {
    /// Applies the kid's own approval of `request` now and queues it, with an alert, for the parents (PLAN.md §15.11).
    /// Nil when it already had an answer, or can't be self-approved.
    func selfApprove(_ request: TimeRequest, name: String?, because reason: String) -> TimeGrant? {
        guard let kid = config.kid, request.canSelfApprove else { return nil }
        let grant = TimeGrant.selfApproved(request, by: kid.displayName, because: reason, at: Date())
        guard Enforcer.apply(grant, now: grant.at) else { return nil }
        let alert = AlertRecord(kidID: kid.id, ruleID: nil, itemID: request.itemID, at: grant.at,
                                title: "\u{26A0}\u{FE0F} \(kid.displayName) self-approved more time",
                                body: "No parent answered. \(describe(request, name: name)) Why: \u{201C}\(reason)\u{201D}")
        do {
            try AppGroup.selfGrants.append(contentsOf: [grant])
            try AppGroup.outbox.append(contentsOf: [alert])
        } catch {
            try? AppGroup.journal.append(.note("self-approval not queued: \(error)"))
        }
        return grant
    }
}
