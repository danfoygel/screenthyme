import FamilyControls
import SwiftUI
import ThymeCore

/// Ask for more time (PLAN.md §15.4), opened from a block page's button or from the Screen Time section. A Downtime
/// block page can't say which app it covered, so the kid picks it in Apple's picker (names, icons, search).
struct AskForTimeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var item: TrackedItem?
    @State private var category: TrackedItem?
    @State private var picking = false
    @State private var selection = FamilyActivitySelection()
    @State private var minutes: Int? = 15
    @State private var note = ""
    @State private var sent: TimeRequest?
    @State private var answer: TimeGrant?

    init(ask: ShieldContext.Ask? = nil) {
        let target = ask.map { ShieldContext().target($0) }
        _item = State(initialValue: target?.item)
        _category = State(initialValue: target?.category)
    }

    var body: some View {
        let context = ShieldContext()
        let target = item.map { context.target(item: $0) }
            ?? category.map { ShieldContext.Target(item: nil, category: $0, name: context.name(of: $0)) }
        let reason = target.flatMap { context.reason(for: $0) }
        NavigationStack {
            Form {
                Section("App") {
                    if let item {
                        ItemName(item: item)
                    } else if let category {
                        LabeledContent { ItemName(item: category) } label: { Text("Blocked by category") }
                    }
                    Button(item == nil ? "Choose the app" : "Choose another app") { picking = true }
                        .disabled(sent != nil)
                }
                if let target, let reason {
                    Section {
                        Text(context.subtitle(for: target, reason: reason))
                    } header: {
                        Text(context.title(for: reason))
                    }
                    if sent == nil {
                        Section("How much more time") {
                            Picker("Time", selection: $minutes) {
                                ForEach(ShieldContext.requestChoices, id: \.self) { choice in
                                    Text(label(choice, reason)).tag(choice)
                                }
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        }
                        Section("Note for your parents") {
                            TextField("Optional", text: $note, axis: .vertical)
                        }
                        Section {
                            Button("Send") { send(target, context) }
                                .disabled(context.requestScope(for: target) == nil)
                        } footer: {
                            if item == nil, case .downtime = reason {
                                Text("Choose the app, or this asks for Downtime off on the whole phone.")
                            }
                        }
                    }
                } else if item != nil {
                    Section { Text("This app isn't blocked right now.") }
                }
                if let sent {
                    Section("Your request") {
                        if let answer {
                            if answer.approved {
                                Label("\(answer.by) said yes: \(ShieldContext.describe(minutes: answer.minutes)).",
                                      systemImage: "checkmark.circle").foregroundStyle(.green)
                            } else {
                                Label("\(answer.by) said no.", systemImage: "xmark.circle")
                            }
                        } else {
                            Label("Asked for \(ShieldContext.describe(minutes: sent.minutes)). Waiting for an answer…",
                                  systemImage: "hourglass")
                            if let parent = model.nearby.peers.first {
                                Label("\(parent.hello.name)'s phone is nearby and has your request.",
                                      systemImage: "antenna.radiowaves.left.and.right")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Ask for more time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .familyActivityPicker(headerText: "Choose the app", isPresented: $picking, selection: $selection)
            .onChange(of: selection) {
                guard let kid = model.config.kid, let token = selection.applicationTokens.first else { return }
                item = AppScan.item(for: token, kid: kid)
            }
            .task(id: sent?.id) { await waitForAnswer() }
        }
    }

    private func label(_ minutes: Int?, _ reason: BlockReason) -> String {
        if minutes == nil, case .downtime = reason { return "Until Downtime ends" }
        return ShieldContext.describe(minutes: minutes).capitalizedFirst
    }

    private func send(_ target: ShieldContext.Target, _ context: ShieldContext) {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        sent = context.request(target, minutes: minutes, note: note.isEmpty ? nil : note)
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
