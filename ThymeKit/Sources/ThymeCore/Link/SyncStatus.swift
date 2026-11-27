import Foundation

/// The parent's Kids screen while iCloud can't be reached: what it shows is the mirror as of the last fetch, live only
/// for kids whose phone is connected nearby (PLAN.md §17).
public struct OfflineNotice: Sendable, Hashable {
    /// The last fetch that succeeded; nil when none has on this phone.
    public var syncedAt: Date?
    /// How to see the kids live, unless every kid already is.
    public var hint: String?

    public func headline(time: (Date) -> String) -> String {
        syncedAt.map { "Offline. Showing what synced at \(time($0))." } ?? "Offline. Nothing has synced yet."
    }
}

public enum SyncStatus {
    /// Nil while online. `kids` are those on the Kids screen, `nearby` the ones whose phone is connected now.
    public static func notice(syncedAt: Date?, isOffline: Bool, kids: Set<UUID>, nearby: Set<UUID>,
                              bluetoothOn: Bool) -> OfflineNotice? {
        guard isOffline else { return nil }
        let hint: String? = if kids.isSubset(of: nearby) && !kids.isEmpty {
            nil
        } else if bluetoothOn {
            "Open ScreenThyme on a kid's phone nearby to see it live."
        } else {
            "Turn on Bluetooth and open ScreenThyme on a kid's phone nearby to see it live."
        }
        return OfflineNotice(syncedAt: syncedAt, hint: hint)
    }
}
