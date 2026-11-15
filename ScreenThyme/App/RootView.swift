import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.config.role {
            case .unset: RoleSelectionView()
            case .kid: KidHomeView()
            case .parent: ParentRootView()
            }
        }
        .alert("ScreenThyme", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
    }
}

/// First launch: which phone is this? (PLAN.md §5)
struct RoleSelectionView: View {
    @Environment(AppModel.self) private var model
    @State private var kidName = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("ScreenThyme shows parents which apps their kids use, when, and for how long, a minute or two after it happens.")
                }
                Section("This is a parent's phone") {
                    Button("Set up as parent") {
                        Task { await model.chooseRole(.parent) }
                    }
                }
                Section {
                    TextField("Kid's name", text: $kidName)
                    Button("Set up as kid's phone") {
                        Task { await model.chooseRole(.kid, kidName: kidName) }
                    }
                    .disabled(kidName.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("This is a kid's phone")
                } footer: {
                    Text("A parent needs to approve Screen Time access on this phone next.")
                }
                Section {
                    Toggle("Single-phone test mode", isOn: Binding(
                        get: { model.config.testMode },
                        set: { value in
                            model.update { config in
                                config.testMode = value
                                config.authMode = value ? .individual : .child
                            }
                        }))
                } footer: {
                    Text("For development: lets one phone switch between kid and parent, use individual (adult) authorization, and upload as fake kids.")
                }
            }
            .navigationTitle("Welcome")
        }
    }
}
