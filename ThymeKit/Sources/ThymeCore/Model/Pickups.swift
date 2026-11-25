import Foundation

/// Apple's pickups and notifications on a kid's phone in one day, per hour and per app, as of `updatedAt` (PLAN.md
/// §13). Apple files a pickup under the first app used after it, or as "without an app" when none was (the lock
/// screen, Control Center); notifications only under apps. One record per kid per day, overwritten as the day goes on.
public struct PickupReport: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kidID: UUID
    public var day: DayKey
    public var updatedAt: Date
    /// Hours with any pickup or notification, oldest first.
    public var hours: [Hour]

    public struct Hour: Codable, Sendable, Hashable {
        public var start: Date
        public var pickupsWithoutApp: Int
        /// Apple's first pickup in the hour. It reads as the hour's start when the phone was already in use then.
        public var firstPickup: Date?
        /// By item id, apps with a pickup or notification only.
        public var apps: [AppCounts]

        public init(start: Date, pickupsWithoutApp: Int, firstPickup: Date?, apps: [AppCounts]) {
            self.start = start
            self.pickupsWithoutApp = pickupsWithoutApp
            self.firstPickup = firstPickup
            self.apps = apps.filter { $0.pickups > 0 || $0.notifications > 0 }.sorted { $0.itemID.uuidString < $1.itemID.uuidString }
        }

        public var pickups: Int { pickupsWithoutApp + apps.reduce(0) { $0 + $1.pickups } }
        public var notifications: Int { apps.reduce(0) { $0 + $1.notifications } }
        var isEmpty: Bool { pickupsWithoutApp == 0 && apps.isEmpty }
    }

    public struct AppCounts: Codable, Sendable, Hashable {
        public var itemID: UUID
        /// To name apps with notifications but no use yet, which have no item: an app's first use makes one, and
        /// alerts parents to a new app.
        public var bundleID: String
        public var pickups: Int
        public var notifications: Int

        public init(itemID: UUID, bundleID: String, pickups: Int, notifications: Int) {
            self.itemID = itemID
            self.bundleID = bundleID
            self.pickups = pickups
            self.notifications = notifications
        }
    }

    public init(kidID: UUID, day: DayKey, updatedAt: Date, hours: [Hour]) {
        self.id = Replay.stableUUID("pickups", kidID.uuidString, day.description)
        self.kidID = kidID
        self.day = day
        self.updatedAt = updatedAt
        self.hours = hours.filter { !$0.isEmpty }.sorted { $0.start < $1.start }
    }

    /// All of the day's pickups, with an app or without.
    public var pickups: Int { hours.reduce(0) { $0 + $1.pickups } }
    public var pickupsWithoutApp: Int { hours.reduce(0) { $0 + $1.pickupsWithoutApp } }
    public var notifications: Int { hours.reduce(0) { $0 + $1.notifications } }
    public var firstPickup: Date? { hours.compactMap(\.firstPickup).min() }

    /// The day's counts per app, most pickups and notifications first.
    public var apps: [AppCounts] {
        var totals: [UUID: AppCounts] = [:]
        for app in hours.flatMap(\.apps) {
            var total = totals[app.itemID] ?? AppCounts(itemID: app.itemID, bundleID: app.bundleID, pickups: 0, notifications: 0)
            total.pickups += app.pickups
            total.notifications += app.notifications
            totals[app.itemID] = total
        }
        return totals.values.sorted {
            ($0.pickups + $0.notifications, $1.itemID.uuidString) > ($1.pickups + $1.notifications, $0.itemID.uuidString)
        }
    }
}

/// A kid phone's pickup reports waiting to go up (App Group `pickups.json`). A report is queued only when its counts
/// changed, and stays queued until a report at least as new is uploaded.
public struct PickupOutbox: Codable, Sendable, Equatable {
    public private(set) var pending: [PickupReport] = []
    /// The newest report recorded, to tell whether the next one changed anything.
    public private(set) var latest: PickupReport?

    public init() {}

    /// Queues `report` if its counts differ from the last one recorded for its day; true if they did.
    @discardableResult
    public mutating func record(_ report: PickupReport) -> Bool {
        if let latest, latest.day == report.day, latest.hours == report.hours { return false }
        latest = report
        pending.removeAll { $0.id == report.id }
        pending.append(report)
        return true
    }

    /// Drops what was uploaded; a report recorded since then stays.
    public mutating func markUploaded(_ reports: [PickupReport]) {
        pending.removeAll { report in reports.contains { $0.id == report.id && $0.updatedAt >= report.updatedAt } }
    }
}
