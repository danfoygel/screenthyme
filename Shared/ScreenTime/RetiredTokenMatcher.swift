import DeviceActivity
import Foundation

/// The retired minute-of-use matcher (activity `tm`, events `m.<item id>`; history before screenshot pairing,
/// PLAN.md §15.6). Phones that still have it registered stop it at app launch; until then its callbacks are ignored.
enum RetiredTokenMatcher {
    static var activity: DeviceActivityName { DeviceActivityName("tm") }

    static func owns(activity name: String, event: String? = nil) -> Bool {
        name == activity.rawValue || event?.hasPrefix("m.") == true
    }

    static func stop() {
        let center = DeviceActivityCenter()
        if center.activities.contains(activity) {
            center.stopMonitoring([activity])
            try? AppGroup.journal.append(.note("token match: retired, stopped tm"))
        }
        try? FileManager.default.removeItem(at: AppGroup.container.appending(path: "token-match.json"))
    }
}
