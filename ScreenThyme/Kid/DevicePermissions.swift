import CoreBluetooth
import CoreTelephony
import Foundation
import ThymeCore
import UIKit

/// The switches in Settings the kid can turn off for ScreenThyme. No app can lock them (Apple's own Content & Privacy
/// Restrictions lock a few), so each heartbeat reports them and parents are told (`HealthEvaluator`).
/// Notifications aren't among them: the kid app neither asks for nor posts any.
@MainActor enum DevicePermissions {
    /// Kept alive: a new instance says "unknown" until CoreTelephony has looked.
    private static let telephony = CTCellularData()

    /// Called at launch, so the cellular answer is in by the first heartbeat.
    static func prepare() {
        _ = telephony
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

    static var lowPowerMode: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
}
