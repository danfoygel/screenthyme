import AVFoundation
import CloudKit
import CoreBluetooth
import CoreTelephony
import FamilyControls
import Foundation
import ThymeCore
import UIKit
import UserNotifications

/// This phone's answer for each `DevicePermission`: a kid's heartbeat carries the ones a kid's phone needs, and
/// Debug → Permissions shows them all.
@MainActor enum DevicePermissions {
    /// Kept alive: a new instance says "unknown" until CoreTelephony has looked.
    private static let telephony = CTCellularData()
    /// iCloud's last answer: it comes asynchronously, and heartbeats are made synchronously (`makeHeartbeat`).
    private(set) static var iCloud: PermissionState?
    private static let localNetworkKey = "localNetworkPermission"

    /// Called at launch, so the cellular answer is in by the first heartbeat.
    static func prepare() {
        _ = telephony
    }

    /// Asks again for the answers that come asynchronously.
    static func refresh() async {
        iCloud = switch try? await FamilyService.container.accountStatus() {
        case .available: .allowed
        case .noAccount, .restricted: .denied
        default: nil
        }
    }

    /// This phone's answer now; nil when iOS can't say (or, for Photos, never asks; for Location, places aren't watched).
    static func state(_ permission: DevicePermission) async -> PermissionState? {
        if permission == .iCloud { await refresh() }
        return switch permission {
        case .screenTime: screenTime
        case .notifications:
            switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
            case .authorized, .provisional, .ephemeral: .allowed
            case .notDetermined: .notAsked
            default: .denied
            }
        case .backgroundRefresh: backgroundRefresh
        case .cellularData: cellularData
        case .localNetwork: localNetwork
        case .bluetooth: bluetooth
        case .iCloud: iCloud
        case .location: location
        case .camera:
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: .allowed
            case .notDetermined: .notAsked
            default: .denied
            }
        case .photos: nil
        }
    }

    /// Only data access counts: plain approval has no per-app data (`HealthIssue.dataAccessLost`).
    static var screenTime: PermissionState {
        switch AuthorizationCenter.shared.authorizationStatus {
        case .approvedWithDataAccess: .allowed
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    static var backgroundRefresh: PermissionState {
        UIApplication.shared.backgroundRefreshStatus == .available ? .allowed : .denied
    }

    static var cellularData: PermissionState? {
        switch telephony.restrictedState {
        case .notRestricted: .allowed
        case .restricted: .denied
        case .restrictedStateUnknown: nil
        @unknown default: nil
        }
    }

    static var bluetooth: PermissionState {
        switch CBManager.authorization {
        case .allowedAlways: .allowed
        case .notDetermined: .notAsked
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    /// No API says: the nearby link finds out when its listener or browser starts (`NearbyLink.sawLocalNetwork`), and
    /// that's kept for heartbeats sent while the link is off.
    static var localNetwork: PermissionState? {
        UserDefaults.standard.string(forKey: localNetworkKey).flatMap(PermissionState.init)
    }

    static func saw(localNetwork state: PermissionState) {
        UserDefaults.standard.set(state.rawValue, forKey: localNetworkKey)
    }

    /// Only while the location test watches places (`PlaceWatcher`).
    static var location: PermissionState? { PlaceWatcher.shared.permission }

    static var lowPowerMode: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
}
