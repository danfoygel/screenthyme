import DeviceActivity
import FamilyControls
import SwiftUI
import ThymeCore

/// The kid's phone (PLAN.md §4.9): an honest status screen. Setup steps are for a parent.
struct KidHomeView: View {
    @Environment(AppModel.self) private var model
    @State private var scan = AppScan.load()
    @State private var pickingCategories = false
    @State private var pickingApps = false

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
                    if let upload = model.lastUploadAt {
                        LabeledContent("Last upload", value: Format.relative(upload))
                    }
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
                        Button("Choose categories (\(scan.categories.categoryTokens.count))") { pickingCategories = true }
                        Button("Choose apps (\(scan.apps.applicationTokens.count) of \(AppScan.maxApps))") { pickingApps = true }
                    } header: {
                        Text("Apps for Screen Time")
                    } footer: {
                        Text("For a parent. Under Categories, select All Apps & Categories. Under Apps, pick the apps to block, limit or allow on their own, including ScreenThyme. Everything else is covered by its category.")
                            .foregroundStyle(scan.apps.applicationTokens.count > AppScan.maxApps ? .red : .secondary)
                    }
                    .familyActivityPicker(headerText: "Select All Apps & Categories", isPresented: $pickingCategories,
                                          selection: $scan.categories)
                    .familyActivityPicker(headerText: "Up to \(AppScan.maxApps) apps", isPresented: $pickingApps,
                                          selection: $scan.apps)
                    .onChange(of: pickingCategories) { if !pickingCategories { AppScan.save(scan, kid: kid) } }
                    .onChange(of: pickingApps) { if !pickingApps { AppScan.save(scan, kid: kid) } }
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
            .refreshable {
                await model.sampleNow()
                await model.flush()
                await model.refresh()
            }
        }
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
