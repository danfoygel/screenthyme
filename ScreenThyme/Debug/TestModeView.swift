import SwiftUI
import ThymeCore

/// The switch into test mode, shown in parent Settings and the kid's Debug screen.
struct TestModeSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section("Development") {
            Toggle("Single-phone test mode", isOn: Binding(get: { model.config.testMode }, set: { value in
                model.update { config in
                    config.testMode = value
                    config.authMode = value ? .individual : .child
                }
            }))
            if model.config.testMode {
                NavigationLink("Test mode") { TestModeView() }
            }
        }
    }
}

/// Single-phone test mode (PLAN.md §7.1): switch roles and kid identity, pick the authorization kind.
struct TestModeView: View {
    @Environment(AppModel.self) private var model
    @State private var newKidName = ""

    var body: some View {
        Form {
            Section {
                Picker("Role", selection: Binding(get: { model.config.role }, set: { role in
                    Task { await model.chooseRole(role, kidName: model.config.kid?.displayName ?? "Test kid") }
                })) {
                    Text("Kid").tag(SharedConfig.Role.kid)
                    Text("Parent").tag(SharedConfig.Role.parent)
                }
                .pickerStyle(.segmented)
                Picker("Authorization", selection: Binding(get: { model.config.authMode }, set: { mode in
                    model.update { $0.authMode = mode }
                })) {
                    Text("Child (Family Sharing)").tag(SharedConfig.AuthMode.child)
                    Text("Individual (adult)").tag(SharedConfig.AuthMode.individual)
                }
            } footer: {
                Text("Individual authorization lets an adult's phone capture its own usage. Capture is the same; parent approval and undeletability are .child-only.")
            }

            Section {
                LabeledContent("Uploading as", value: model.config.kid?.displayName ?? "—")
                ForEach(model.data.sortedKids.filter { $0.id != model.config.kid?.id }) { kid in
                    Button("Upload as \(kid.displayName)") { Task { await model.switchKidIdentity(to: kid) } }
                }
                HStack {
                    TextField("New test kid", text: $newKidName)
                    Button("Add") {
                        let kid = Kid(displayName: newKidName, colorIndex: model.data.kids.count, isTest: true)
                        newKidName = ""
                        Task { await model.switchKidIdentity(to: kid) }
                    }
                    .disabled(newKidName.isEmpty)
                }
            } header: {
                Text("Kid identity")
            } footer: {
                Text("Switching identity stops monitoring and forgets this phone's apps and samples; start monitoring again afterwards.")
            }

            Section {
                NavigationLink("Replay tool") { ReplayView() }
                Button("Forget test kids on this phone", role: .destructive) {
                    for kid in model.data.sortedKids where kid.isTest { model.data.forget(kid: kid.id) }
                }
            } footer: {
                Text("Test data goes to the CloudKit development environment only (development builds).")
            }
        }
        .navigationTitle("Test mode")
    }
}
