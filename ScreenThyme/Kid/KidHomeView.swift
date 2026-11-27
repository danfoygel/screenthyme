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
                Section {
                    NavigationLink { KidAppsView() } label: { Label("Apps", systemImage: "square.grid.2x2") }
                    NavigationLink {
                        KidTimelineView(source: .thisPhone, day: DayKey(Date()))
                    } label: {
                        Label("Day timeline", systemImage: "calendar.day.timeline.left")
                    }
                    NavigationLink {
                        CategoryTimeView(source: .thisPhone, day: DayKey(Date()))
                    } label: {
                        Label("Time by category", systemImage: "chart.bar.horizontal.page")
                    }
                } footer: {
                    Text("How long you've used each app, and the Downtime and limits for it. The timeline shows when, as your parents see it, and Time by category adds up games, social apps and the rest.")
                }
                Section {
                    NavigationLink("Report a problem") { BugReportView() }
                } footer: {
                    Text("Something not working right? Tell us, and add screenshots if they help.")
                }
                Section("Status") {
                    LabeledContent("Kid", value: model.config.kid?.displayName ?? "—")
                    LabeledContent("Screen Time access", value: model.authorizationLabel)
                    LabeledContent("Family", value: familyStatus)
                    LabeledContent("Monitoring", value: model.monitoringLabel)
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
                    if open, model.config.epoch == nil {
                        Button("Start monitoring") { Task { await model.startMonitoring() } }
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
                        if open {
                            Button("Scan apps (\(scan.all.applicationTokens.count) apps)") { pickingAll = true }
                        }
                        NavigationLink {
                            CameraPairingView()
                        } label: {
                            // As parents count them: apps used this week, not those whose use was Safari's on their website.
                            let items = AppGroup.loadItems()
                            let used = AppGroup.load(WebMirror.self, from: AppGroup.webMirrorURL)?.used(
                                today: DayKey(Date()), items: Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
                            let count = TokenPairing.unmatched(items, lastImport: TokenPairingView.lastImport(), used: used).toMatch.count
                            LabeledContent("Match with a parent's camera", value: count == 0 ? "" : "\(count) new")
                                .foregroundStyle(count == 0 ? Color.primary : .orange)
                        }
                        if open {
                            NavigationLink("Match apps by screenshot") { TokenPairingView() }
                            // Once, at setup; again only if its token stops working (a new authorization can void it).
                            Button(scan.screenThyme.applicationTokens.isEmpty ? "Choose ScreenThyme" : "ScreenThyme chosen: choose again") {
                                pickingSelf = true
                            }
                        }
                    } header: {
                        Text("Apps for Screen Time")
                    } footer: {
                        Text("For a parent. Scan: select All Apps & Categories, then Done; scan again after installing apps. Then choose ScreenThyme alone, so Downtime never blocks it. Match after a scan, and when new apps have been used, so limits count them: with a parent's phone nearby, or by screenshot.")
                    }
                    .familyActivityPicker(headerText: "Select All Apps & Categories", isPresented: $pickingAll,
                                          selection: $scan.all)
                    .familyActivityPicker(headerText: "Select ScreenThyme only", isPresented: $pickingSelf,
                                          selection: $scan.screenThyme)
                    .onChange(of: pickingAll) { if !pickingAll { save(kid) } }
                    .onChange(of: pickingSelf) {
                        guard !pickingSelf else { return }
                        // Whatever is picked here passes Downtime, limits and Blocked: ScreenThyme alone, or nothing.
                        let pick = scan.screenThyme
                        guard pick.applicationTokens.count == 1, pick.categoryTokens.isEmpty, pick.webDomainTokens.isEmpty
                        else {
                            scan.screenThyme = AppScan.load().screenThyme
                            model.message = "Choose ScreenThyme alone: one app, no categories or websites."
                            return
                        }
                        save(kid)
                    }
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
                ParentControlsSection()
                // A kid could otherwise switch on test mode and make this phone a parent's (PLAN.md §7.1).
                if model.config.testMode {
                    TestModeSection()
                }
            }
            .navigationTitle("ScreenThyme")
            .bugButton(help: .kidHome)
            // A parent's phone nearby opened its camera to match apps.
            .navigationDestination(isPresented: Binding { model.cameraPairingRequested } set: { model.cameraPairingRequested = $0 }) {
                CameraPairingView()
            }
            .sheet(item: $ask) { AskForTimeView(ask: $0.ask) }
            .onChange(of: scenePhase, initial: true) {
                if scenePhase == .active, let taken = ShieldContext.Ask.take() { ask = AskSheet(ask: taken) }
            }
            // Names and icons for the apps and websites this phone has used, as on a parent's phone.
            .task { await AppCatalog.shared.lookUp(AppGroup.loadItems()) }
            .refreshable {
                await model.sampleNow()
                await model.flush()
                await model.refresh()
            }
        }
        // Locking goes back to the top, out of Debug or matching.
        .id(open)
    }

    private var open: Bool { model.parentControlsOpen }

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
}

/// The parent controls' state, and Debug while they're open (`ParentUnlock`).
private struct ParentControlsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            if let unlock = model.parentUnlock {
                LabeledContent("Unlocked by \(unlock.by)", value: "until \(unlock.until.formatted(date: .omitted, time: .shortened))")
                Button("Lock now") { model.lockParentControls() }
            } else if !model.parentControlsOpen {
                Label("Locked", systemImage: "lock")
            }
            if model.parentControlsOpen {
                NavigationLink("Debug") { KidDebugView() }
            }
        } header: {
            Text("Parent controls")
        } footer: {
            if !model.parentControlsOpen {
                Text("Scanning apps, matching by screenshot, choosing ScreenThyme, starting monitoring and Debug. A parent unlocks them from their phone, near this one: Settings › Kids › \(model.config.kid?.displayName ?? "this kid") › Unlock.")
            }
        }
    }
}

private struct AskSheet: Identifiable {
    let id = UUID()
    let ask: ShieldContext.Ask
}
