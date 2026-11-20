import BackgroundTasks
import CloudKit
import SwiftUI
import UIKit
import UserNotifications

@main
struct ScreenThymeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(AppModel.shared)
                .task { await AppModel.shared.launched() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await AppModel.shared.launched() }
            } else if phase == .background {
                // iOS suspends the sockets anyway; closing them lets the other phone notice at once.
                AppModel.shared.stopNearby()
                if AppModel.shared.isKid {
                    // Counts the time the kid spent looking at the app.
                    EnergyMeter.record(.app, isCallback: false)
                }
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BackgroundRefresh.register()
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()
        if SharedConfig.load().role == .kid {
            // A relaunch for a geofence crossing or a visit has no scene: pick the event up here.
            PlaceWatcher.shared.start()
        }
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    /// The same token serves CloudKit's pushes and bug fixes' (`BugReportQueue.pushToken`).
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        AppModel.shared.bugReports.pushToken = deviceToken.map { String(format: "%02x", $0) }.joined()
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await AppModel.shared.handlePush()
        return .newData
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// Receives CloudKit share invitations (the family invite link).
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            accept(metadata)
        }
    }

    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        accept(cloudKitShareMetadata)
    }

    private func accept(_ metadata: CKShare.Metadata) {
        Task { await AppModel.shared.acceptShare(metadata) }
    }
}

/// Opportunistic wake-ups: kids flush and send a heartbeat; parents fetch (PLAN.md §4.7).
enum BackgroundRefresh {
    static let identifier = "com.danfoygel.screenthyme.refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            schedule()
            nonisolated(unsafe) let task = task
            let work = Task { @MainActor in
                await AppModel.shared.backgroundRefresh()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
