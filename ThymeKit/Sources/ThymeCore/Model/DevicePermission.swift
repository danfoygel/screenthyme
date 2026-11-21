import Foundation

/// Everything ScreenThyme could ask iOS for, used or not: Debug → Permissions lists them all, with this phone's answers.
/// No app can lock them (Apple's own Content & Privacy Restrictions lock a few), so a kid's heartbeat reports the ones
/// a kid's phone needs and parents are told when one is off (`HealthEvaluator`).
public enum DevicePermission: String, Sendable, Hashable, CaseIterable {
    /// Family Controls. Heartbeats carry it as `Heartbeat.authStatus`, checked on its own (`HealthIssue.notAuthorized`).
    case screenTime
    /// Parents' alerts. The kid app neither asks for nor posts any.
    case notifications
    /// Pings and background heartbeats. Capture and shields run in the extensions and don't need it.
    case backgroundRefresh
    /// Uploads away from Wi-Fi.
    case cellularData
    /// The nearby link over Wi-Fi (PLAN.md §17).
    case localNetwork
    /// The nearby link when Wi-Fi is off (PLAN.md §17).
    case bluetooth
    /// Sync: signed in, with iCloud on for ScreenThyme.
    case iCloud
    /// Matching a kid's scanned apps by a parent's camera (PLAN.md §15.6).
    case camera
    /// Never asked: screenshots come through Apple's photo picker.
    case photos
    /// Where apps get used, on a kid's phone watching places (PLAN.md §19): Always, with Precise Location.
    case location

    public var title: String {
        switch self {
        case .screenTime: "Screen Time"
        case .notifications: "Notifications"
        case .backgroundRefresh: "Background App Refresh"
        case .cellularData: "Cellular data"
        case .localNetwork: "Local Network"
        case .bluetooth: "Bluetooth"
        case .iCloud: "iCloud"
        case .camera: "Camera"
        case .photos: "Photos"
        case .location: "Location"
        }
    }

    /// What a kid's or a parent's phone uses it for; nil where that phone never asks for it.
    public func purpose(onKidPhone: Bool) -> String? {
        switch (self, onKidPhone) {
        case (.screenTime, true): "Usage data, and Downtime and limits"
        case (.notifications, false): "Alerts and requests for more time"
        case (.backgroundRefresh, true): "Answers parents' pings, and sends updates while ScreenThyme is closed"
        case (.backgroundRefresh, false): "Checks kids' phones' health while ScreenThyme is closed"
        case (.cellularData, _): "Syncs away from Wi-Fi"
        case (.localNetwork, true): "Sends usage to a parent's phone nearby, with no internet"
        case (.localNetwork, false): "Gets usage from kids' phones nearby, with no internet"
        case (.bluetooth, _): "The nearby link when Wi-Fi is off"
        case (.iCloud, _): "Syncs with the family"
        case (.camera, false): "Matches a kid's apps by reading the codes on their screen"
        case (.location, true): "Notes where apps get used, while Debug → Places watches places"
        default: nil
        }
    }

    /// Why neither phone asks for it.
    public var notUsedReason: String? {
        switch self {
        case .photos: "Screenshots come through Apple's photo picker, which hands over only the ones picked and needs no permission."
        default: nil
        }
    }

    /// Where to turn it back on.
    public var settingsPath: String? {
        switch self {
        case .screenTime: "A parent approves it from ScreenThyme's Allow Screen Time access"
        case .notifications, .localNetwork, .bluetooth, .camera: "Settings → Apps → ScreenThyme → \(title)"
        case .backgroundRefresh: "Settings → General → Background App Refresh, and Low Power Mode off"
        case .cellularData: "Settings → Cellular → ScreenThyme"
        case .iCloud: "Settings → Apple Account → iCloud: signed in, with ScreenThyme on"
        case .location: "Settings → Apps → ScreenThyme → Location: Always, with Precise Location on"
        case .photos: nil
        }
    }

    /// For parents' alerts.
    public var offSummary: String {
        switch self {
        case .iCloud: "iCloud isn't available to ScreenThyme: signed out, or off for it"
        case .location: "Location isn't “Always” and precise for ScreenThyme: places aren't watched"
        default: "\(title) is off for ScreenThyme"
        }
    }

    /// As a kid's heartbeat reports it; nil for the ones heartbeats don't carry (Screen Time is `authStatus`), from older
    /// builds, and when the phone couldn't tell.
    public func state(in heartbeat: Heartbeat) -> PermissionState? {
        switch self {
        case .backgroundRefresh: heartbeat.backgroundRefresh
        case .cellularData: heartbeat.cellularData
        case .localNetwork: heartbeat.localNetwork
        case .bluetooth: heartbeat.bluetooth
        case .iCloud: heartbeat.iCloud
        case .location: heartbeat.location
        case .screenTime, .notifications, .camera, .photos: nil
        }
    }
}
