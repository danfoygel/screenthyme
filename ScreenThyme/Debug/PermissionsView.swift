import AVFoundation
import FamilyControls
import SwiftUI
import ThymeCore
import UIKit

/// Everything ScreenThyme could ask iOS for (`DevicePermission`): this phone's answers, what each kid's phone last
/// reported (on a parent's phone), and the ones neither phone asks for. Parents are notified when a kid's phone has
/// one off (`HealthEvaluator`).
struct PermissionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var states: [DevicePermission: PermissionState] = [:]

    var body: some View {
        let onKidPhone = model.isKid
        let used = DevicePermission.allCases.filter { $0.purpose(onKidPhone: onKidPhone) != nil }
        Form {
            Section {
                ForEach(used, id: \.self) { permission in
                    PermissionRow(permission: permission, purpose: permission.purpose(onKidPhone: onKidPhone)!,
                                  state: states[permission],
                                  detail: permission == .screenTime ? model.authorizationLabel : nil)
                    if let ask = ask(permission) {
                        Button(ask.label) { Task { await ask.action(); await load() } }
                    }
                }
                if onKidPhone {
                    LabeledContent("Low Power Mode", value: DevicePermissions.lowPowerMode ? "on: pauses Background App Refresh" : "off")
                }
                Button("Open ScreenThyme in Settings") {
                    UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                }
            } header: {
                Text("This phone (\(onKidPhone ? "kid" : "parent"))")
            } footer: {
                if onKidPhone {
                    Text("Each heartbeat sends these to parents, and their phones notify them when one is off.")
                } else if !model.data.sortedKids.isEmpty {
                    Text("Kids' phones need others: below, as each last reported.")
                }
            }
            if model.isParent {
                ForEach(model.data.sortedKids) { kid in
                    KidPermissionsSection(kid: kid, heartbeat: model.data.heartbeats[kid.id])
                }
            }
            Section("Not used on this phone") {
                ForEach(DevicePermission.allCases.filter { $0.purpose(onKidPhone: onKidPhone) == nil }, id: \.self) { permission in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(permission.title)
                        Text(permission.notUsedReason
                             ?? "\(onKidPhone ? "Parents'" : "Kids'") phones only. \(permission.purpose(onKidPhone: !onKidPhone) ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Permissions")
        .bugButton(help: .permissions)
        .refreshable { await load() }
        // Again on returning from Settings.
        .task(id: scenePhase) { if scenePhase == .active { await load() } }
    }

    private func load() async {
        var states: [DevicePermission: PermissionState] = [:]
        for permission in DevicePermission.allCases {
            states[permission] = await DevicePermissions.state(permission)
        }
        model.authorizationStatus = AuthorizationCenter.shared.authorizationStatus
        self.states = states
    }

    /// The prompts this screen can bring up, for the permissions iOS hasn't asked about yet (or, for Screen Time,
    /// until data access is on). Turning one back on is in Settings only.
    private func ask(_ permission: DevicePermission) -> (label: String, action: () async -> Void)? {
        switch (permission, states[permission]) {
        case (.notifications, .notAsked): ("Ask for notifications", { await Notifier.requestPermission() })
        case (.camera, .notAsked): ("Ask for the camera", { _ = await AVCaptureDevice.requestAccess(for: .video) })
        case (.screenTime, let state) where model.isKid && state != .allowed:
            (model.isAuthorized ? "Allow usage data access" : "Allow Screen Time access", { await model.requestAuthorization() })
        default: nil
        }
    }
}

/// What a kid's phone last reported, from its heartbeat.
private struct KidPermissionsSection: View {
    let kid: Kid
    let heartbeat: Heartbeat?

    var body: some View {
        Section {
            if let heartbeat {
                ForEach(DevicePermission.allCases, id: \.self) { permission in
                    if let purpose = permission.purpose(onKidPhone: true) {
                        PermissionRow(permission: permission, purpose: purpose, state: state(permission, in: heartbeat),
                                      detail: permission == .screenTime ? heartbeat.authStatus : nil)
                    }
                }
                if let lowPower = heartbeat.lowPowerMode {
                    LabeledContent("Low Power Mode", value: lowPower ? "on" : "off")
                }
            } else {
                Text("No heartbeat yet").foregroundStyle(.secondary)
            }
        } header: {
            Text("\(kid.displayName)'s phone")
        } footer: {
            if let heartbeat {
                Text("Reported \(Format.relative(heartbeat.at)), app version \(heartbeat.appVersion). You're notified when one is off. Unknown: an older version, or the phone couldn't tell.")
            }
        }
    }

    private func state(_ permission: DevicePermission, in heartbeat: Heartbeat) -> PermissionState? {
        guard permission == .screenTime else { return permission.state(in: heartbeat) }
        return switch heartbeat.authStatus {
        case HealthEvaluator.dataAccessStatus: .allowed
        case "notDetermined": .notAsked
        default: .denied
        }
    }
}

private struct PermissionRow: View {
    let permission: DevicePermission
    let purpose: String
    let state: PermissionState?
    /// iOS's own word, where ours says less.
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(permission.title)
                Spacer()
                Label(label, systemImage: symbol).foregroundStyle(color)
            }
            Text(purpose).font(.caption).foregroundStyle(.secondary)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            if state != .allowed, let path = permission.settingsPath {
                Text(path).font(.caption).foregroundStyle(state == .denied ? .red : .secondary)
            }
        }
    }

    private var label: String {
        switch state {
        case .allowed: "Allowed"
        case .denied: "Off"
        case .notAsked: "Not asked"
        case nil: "Unknown"
        }
    }

    private var symbol: String {
        switch state {
        case .allowed: "checkmark.circle.fill"
        case .denied: "xmark.octagon.fill"
        case .notAsked: "questionmark.circle"
        case nil: "circle.dashed"
        }
    }

    private var color: Color {
        switch state {
        case .allowed: .green
        case .denied: .red
        case .notAsked: .orange
        case nil: .secondary
        }
    }
}
