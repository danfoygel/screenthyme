import DeviceActivity
import FamilyControls
import SwiftUI
import ThymeCore

/// The kid's phone (PLAN.md §4.9): an honest status screen. Scanning and naming are for a parent.
struct KidHomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showPicker = false
    @State private var selection = FamilyActivitySelection(includeEntireCategory: true)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("This phone shares app usage with your parents.")
                }
                Section("Status") {
                    row("Kid", model.config.kid?.displayName ?? "—")
                    row("Screen Time access", model.authorizationLabel)
                    row("Family", familyStatus)
                    row("Tracking", trackingStatus)
                    row("Last usage event", AppGroup.journal.lastThresholdAt().map(Format.relative) ?? "none yet")
                    row("Waiting to upload", "\(Uploader.backlogCount())")
                    if let upload = model.lastUploadAt {
                        row("Last upload", Format.relative(upload))
                    }
                }
                Section {
                    if !model.isAuthorized {
                        Button("Allow Screen Time access") {
                            Task { await model.requestAuthorization() }
                        }
                    }
                    Button(model.config.epoch == nil ? "Scan all apps" : "Re-scan apps") {
                        selection = FamilyActivitySelection(includeEntireCategory: true)
                        showPicker = true
                    }
                    .disabled(!model.isAuthorized)
                    NavigationLink("Name apps") { NamingView() }
                        .disabled(model.config.items.isEmpty)
                    Button("Upload now") {
                        Task {
                            await model.publishKidIdentity()
                            await model.flush()
                            await model.sendHeartbeat(.manual)
                        }
                    }
                } header: {
                    Text("For a parent")
                } footer: {
                    Text("In the scan, tap \"All Apps & Categories\", then Done. Re-scan after installing new apps.")
                }
                if model.config.family == nil {
                    Section("Join the family") {
                        Text("Open the invite link a parent sent to this phone's Apple Account (Messages or Mail).")
                        if model.config.testMode {
                            Button("Create a family on this phone (test mode)") {
                                Task { await model.createFamily() }
                            }
                        }
                    }
                }
                Section {
                    NavigationLink("Debug") { KidDebugView() }
                }
                TestModeSection()
            }
            .navigationTitle("ScreenThyme")
            .familyActivityPicker(headerText: "Tap \"All Apps & Categories\" to track every app.",
                                  isPresented: $showPicker, selection: $selection)
            .onChange(of: showPicker) { _, showing in
                guard !showing, !selection.applicationTokens.isEmpty || !selection.categoryTokens.isEmpty else { return }
                Task { await model.applyScan(selection) }
            }
            .refreshable {
                await model.flush()
                await model.refresh()
            }
        }
    }

    private var familyStatus: String {
        guard let family = model.config.family else { return "not joined" }
        return family.isOwner ? "owner (this account)" : "joined"
    }

    private var trackingStatus: String {
        guard let epoch = model.config.epoch else { return "not scanned" }
        let apps = model.config.items.filter { $0.active && $0.kind == .app }.count
        let active = Set(DeviceActivityCenter().activities.map(\.rawValue))
        let running = epoch.activityNames.filter(active.contains).count
        return "\(apps) apps · \(running)/\(epoch.activityNames.count) schedules"
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title, value: value)
    }
}

/// Nicknames, for when Apple's labels don't render on the parents' phones (S2). Top apps first.
struct NamingView: View {
    @Environment(AppModel.self) private var model
    @State private var names: [UUID: String] = [:]

    var body: some View {
        let today = DayKey(Date())
        let timeline = Reconstructor.build(model.config.dayInput(today))
        let items = model.config.items
            .filter { $0.active && $0.kind != .category }
            .sorted { (timeline.totals[$0.id]?.lowerMinutes ?? 0, -$0.ordinal) > (timeline.totals[$1.id]?.lowerMinutes ?? 0, -$1.ordinal) }
        List(items) { item in
            HStack {
                ItemName(item: TrackedItem(id: item.id, kidID: item.kidID, kind: item.kind, tokenData: item.tokenData,
                                           ordinal: item.ordinal, firstSeenEpoch: item.firstSeenEpoch))
                    .frame(maxWidth: .infinity, alignment: .leading)
                TextField("Nickname", text: binding(item))
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.words)
            }
        }
        .navigationTitle("Name apps")
        .toolbar {
            Button("Save") { Task { await model.saveNicknames(names) } }
        }
        .onAppear {
            names = Dictionary(uniqueKeysWithValues: model.config.items.map { ($0.id, $0.nickname ?? "") })
        }
    }

    private func binding(_ item: TrackedItem) -> Binding<String> {
        Binding(get: { names[item.id] ?? "" }, set: { names[item.id] = $0 })
    }
}
