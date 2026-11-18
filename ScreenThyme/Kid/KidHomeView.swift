import DeviceActivity
import FamilyControls
import SwiftUI
import ThymeCore

/// The kid's phone (PLAN.md §4.9): an honest status screen. Setup steps are for a parent.
struct KidHomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    /// Opened from a block page's "Ask for more time".
    @State private var ask: AskSheet?
    @State private var scan = AppScan.load()
    @State private var pickingAll = false
    @State private var pickingSelf = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("This phone shares app usage with your parents.")
                }
                KidScreenTimeSection()
                Section("Status") {
                    LabeledContent("Kid", value: model.config.kid?.displayName ?? "—")
                    LabeledContent("Screen Time access", value: model.authorizationLabel)
                    LabeledContent("Family", value: familyStatus)
                    LabeledContent("Monitoring", value: monitoringStatus)
                    LabeledContent("Apps seen", value: "\(AppGroup.loadItems().count)")
                    LabeledContent("Last wake", value: AppGroup.journal.lastThresholdAt().map(Format.relative) ?? "none yet")
                    LabeledContent("Waiting to upload", value: "\(Uploader.backlogCount())")
                    LabeledContent("Parent phone nearby", value: model.nearby.summary)
                    if let upload = model.lastUploadAt {
                        LabeledContent("Last upload", value: Format.relative(upload))
                    }
                }
                Section {
                    Stepper(value: extraMinutes, in: ExtraMinute.allowedMinutes) {
                        LabeledContent("One more minute", value: "\(model.config.extraMinuteLength) min")
                    }
                } header: {
                    Text("Block page")
                } footer: {
                    Text("How long \"One more minute\" on a block page lets an app through, without asking. Once a day for each app.")
                }
                Section {
                    if !model.hasDataAccess {
                        Button(model.isAuthorized ? "Allow usage data access" : "Allow Screen Time access") {
                            Task { await model.requestAuthorization() }
                        }
                    }
                    if model.config.epoch == nil {
                        Button("Start monitoring") { model.startMonitoring() }
                            .disabled(!model.hasDataAccess)
                    }
                    Button("Upload now") {
                        Task {
                            await model.sampleNow()
                            await model.publishKidIdentity()
                            await model.flush()
                            await model.sendHeartbeat(.manual)
                        }
                    }
                } header: {
                    Text("For a parent")
                } footer: {
                    Text("Access needs a parent's approval on this phone, and asking again if it says \"approved\" without data access. After approving, restart the phone once.")
                }
                if model.hasDataAccess, let kid = model.config.kid {
                    Section {
                        Button("Scan apps (\(scan.all.applicationTokens.count) apps)") { pickingAll = true }
                        NavigationLink {
                            TokenPairingView()
                        } label: {
                            let count = TokenPairing.toMatch(AppGroup.loadItems(), lastImport: TokenPairingView.lastImport()).count
                            LabeledContent("Match apps by screenshot", value: count == 0 ? "" : "\(count) new")
                                .foregroundStyle(count == 0 ? Color.primary : .orange)
                        }
                        Button(scan.screenThyme.applicationTokens.isEmpty ? "Choose ScreenThyme" : "ScreenThyme chosen") {
                            pickingSelf = true
                        }
                    } header: {
                        Text("Apps for Screen Time")
                    } footer: {
                        Text("For a parent. Scan: select All Apps & Categories, then Done; scan again after installing apps. Then choose ScreenThyme alone, so Downtime never blocks it. Match by screenshot after a scan, and when new apps have been used, so limits count them.")
                    }
                    .familyActivityPicker(headerText: "Select All Apps & Categories", isPresented: $pickingAll,
                                          selection: $scan.all)
                    .familyActivityPicker(headerText: "Select ScreenThyme only", isPresented: $pickingSelf,
                                          selection: $scan.screenThyme)
                    .onChange(of: pickingAll) { if !pickingAll { save(kid) } }
                    .onChange(of: pickingSelf) { if !pickingSelf { save(kid) } }
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
                // A kid could otherwise switch on test mode and make this phone a parent's (PLAN.md §7.1).
                if model.config.testMode {
                    TestModeSection()
                }
            }
            .navigationTitle("ScreenThyme")
            .sheet(item: $ask) { AskForTimeView(ask: $0.ask) }
            .onChange(of: scenePhase, initial: true) {
                if scenePhase == .active, let taken = ShieldContext.Ask.take() { ask = AskSheet(ask: taken) }
            }
            .refreshable {
                await model.sampleNow()
                await model.flush()
                await model.refresh()
            }
        }
    }

    private var extraMinutes: Binding<Int> {
        Binding { model.config.extraMinuteLength } set: { minutes in model.update { $0.extraMinutes = minutes } }
    }

    private func save(_ kid: Kid) {
        AppScan.save(scan, kid: kid)
    }

    private var familyStatus: String {
        guard let family = model.config.family else { return "not joined" }
        return family.isOwner ? "owner (this account)" : "joined"
    }

    private var monitoringStatus: String {
        guard let epoch = model.config.epoch else { return "not started" }
        let active = Set(DeviceActivityCenter().activities.map(\.rawValue))
        return epoch.activityNames.allSatisfy(active.contains) ? "on" : "stopped (open the app to restart)"
    }
}

private struct AskSheet: Identifiable {
    let id = UUID()
    let ask: ShieldContext.Ask
}
