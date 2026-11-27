import FamilyControls
import SwiftUI
import ThymeCore

/// Ask a parent to put an app on Always Allowed (`BlockReason.alwaysAllow`), from the Screen Time section. The kid
/// picks the app in Apple's picker, like `AskForTimeView`; a parent's approval saves the policy with the app allowed.
struct AskAlwaysAllowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var item: TrackedItem?
    @State private var picking = false
    @State private var selection = FamilyActivitySelection()
    @State private var note = ""
    @State private var sent: TimeRequest?
    @State private var answer: TimeGrant?

    var body: some View {
        let items = Dictionary(AppGroup.loadItems().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let allowed = item.map { AppGroup.loadPolicy()?.isAlwaysAllowed($0.id, items: items) ?? false } ?? false
        NavigationStack {
            Form {
                Section {
                    if let item { ItemName(item: item) }
                    Button(item == nil ? "Choose the app" : "Choose another app") { picking = true }
                } header: {
                    Text("App")
                } footer: {
                    Text("Always Allowed apps work during Downtime and don't count toward limits.")
                }
                if let item {
                    if let sent {
                        Section("Your request") {
                            if let answer {
                                if answer.approved {
                                    Label("\(answer.by) said yes: it's always allowed now.", systemImage: "checkmark.circle")
                                        .foregroundStyle(.green)
                                } else {
                                    Label("\(answer.by) said no.", systemImage: "xmark.circle")
                                }
                            } else {
                                Label("Asked \(Format.relative(sent.at)). Waiting for an answer…", systemImage: "hourglass")
                                if let parent = model.nearby.peers.first {
                                    Label("\(parent.hello.name)'s phone is nearby and has your request.",
                                          systemImage: "antenna.radiowaves.left.and.right")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else if allowed {
                        Section { Text("This app is already always allowed.") }
                    } else {
                        Section("Note for your parents") {
                            TextField("Optional", text: $note, axis: .vertical)
                        }
                        Section {
                            Button("Send") { send(item, items: items) }
                        }
                    }
                }
            }
            .navigationTitle("Ask to always allow")
            .bugButton(help: .askAlwaysAllow)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .familyActivityPicker(headerText: "Choose the app", isPresented: $picking, selection: $selection)
            .onChange(of: selection) {
                guard let kid = model.config.kid, let token = selection.applicationTokens.first else { return }
                item = AppScan.item(for: token, kid: kid)
                // A request already waiting for this app shows instead of a second one.
                sent = item.flatMap { ShieldContext().pendingAlwaysAllow($0.id) }
                answer = nil
            }
            .task(id: sent?.id) { await waitForAnswer() }
        }
    }

    private func send(_ item: TrackedItem, items: [UUID: TrackedItem]) {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = AppCatalog.shared.name(of: item, in: items) ?? "an app"
        sent = ShieldContext().requestAlwaysAllow(item, name: name, note: note.isEmpty ? nil : note)
        model.nearby.sendUpdates()
    }

    /// Uploads the request, then checks for the answer every few seconds while this is open.
    private func waitForAnswer() async {
        guard let sent else { return }
        while answer == nil, !Task.isCancelled {
            await model.flush()
            await KidSync.refreshIfDue(config: model.config)
            answer = Enforcer.loadState().grants.first { $0.grant.requestID == sent.id }?.grant
            if answer == nil { try? await Task.sleep(for: .seconds(5)) }
        }
    }
}
