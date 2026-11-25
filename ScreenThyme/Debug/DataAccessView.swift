import DeviceActivity
import FamilyControls
import ManagedSettings
import SwiftUI
import ThymeCore

/// Test S4: does the iOS 26.4 data-access option work here (development build, this region, this authorization
/// kind), and what does its data look like? Debug-only; nothing here feeds capture or sync.
struct DataAccessView: View {
    @Environment(AppModel.self) private var model
    @State private var lines: [String] = []
    @State private var running = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Authorization", value: String(describing: AuthorizationCenter.shared.authorizationStatus))
                Button("Request authorization again") {
                    Task {
                        await model.requestAuthorization()
                        log("after request: \(AuthorizationCenter.shared.authorizationStatus)")
                    }
                }
            } footer: {
                Text("With the app-and-website-usage entitlement, approval can come back as approvedWithDataAccess.")
            }
            Section("Fetch") {
                Button("Today's activity (cached)") { run { try await fetchActivity(policy: .cached) } }
                Button("Today's activity (live)") { run { try await fetchActivity(policy: .live) } }
                Button("Installed apps and visited sites") { run { try await fetchInventory() } }
                if running { ProgressView() }
            }
            Section("Results") {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced())
                }
            }
        }
        .navigationTitle("Data access (S4)")
        .bugButton()
    }

    private func run(_ work: @escaping () async throws -> Void) {
        lines = []
        running = true
        Task {
            do { try await work() } catch { log("ERROR: \(error)") }
            running = false
            // Also appended to a file, so the full results can be copied off the phone (devicectl).
            let file = JSONLinesFile<String>(url: AppGroup.container.appending(path: "s4-results.jsonl"))
            try? file.append(contentsOf: ["--- \(Date().formatted(date: .omitted, time: .standard))"] + lines)
        }
    }

    private func log(_ line: String) {
        lines.append(line)
    }

    private func fetchActivity(policy: DeviceActivityData.Policy) async throws {
        let today = Calendar.current.dateInterval(of: .day, for: Date())!
        let filter = DeviceActivityFilter(segment: .hourly(during: today))
        let started = Date()
        var devices = 0
        for try await data in DeviceActivityData.activityData(filteredBy: filter, using: policy) {
            devices += 1
            log("user \(data.user.role) · device \(data.device.name ?? "?") · updated \(data.lastUpdatedDate.formatted(date: .omitted, time: .standard))")
            // Pickups and notifications: are they filled in outside Apple's report extension, or always zero?
            var perApp: [String: (seconds: TimeInterval, pickups: Int, notifications: Int)] = [:]
            var day = (pickups: 0, withoutApp: 0, notifications: 0, firstPickup: Date?.none)
            for await segment in data.activitySegments {
                var pickups = 0, notifications = 0
                for await category in segment.categories {
                    for await app in category.applications {
                        let name = app.application.localizedDisplayName ?? app.application.bundleIdentifier ?? "?"
                        let key = "\(name) [\(app.application.bundleIdentifier ?? "no bundle id")]"
                        var use = perApp[key] ?? (0, 0, 0)
                        use.seconds += app.totalActivityDuration
                        use.pickups += app.numberOfPickups
                        use.notifications += app.numberOfNotifications
                        perApp[key] = use
                        pickups += app.numberOfPickups
                        notifications += app.numberOfNotifications
                    }
                }
                let withoutApp = segment.totalPickupsWithoutApplicationActivity
                day.pickups += pickups
                day.withoutApp += withoutApp
                day.notifications += notifications
                if let first = segment.firstPickup, day.firstPickup.map({ first < $0 }) ?? true { day.firstPickup = first }
                let minutes = Int(segment.totalActivityDuration / 60)
                guard minutes > 0 || pickups + withoutApp + notifications > 0 else { continue }
                let first = segment.firstPickup?.formatted(date: .omitted, time: .shortened) ?? "–"
                let longest = segment.longestActivity.map { "\(Int($0.duration / 60)) min" } ?? "–"
                log("  \(segment.dateInterval.start.formatted(date: .omitted, time: .shortened))–\(segment.dateInterval.end.formatted(date: .omitted, time: .shortened)): \(minutes) min · \(pickups)+\(withoutApp) pickups · \(notifications) notif · first \(first) · longest \(longest)")
            }
            log("  today: \(day.pickups + day.withoutApp) pickups (\(day.withoutApp) without an app) · \(day.notifications) notifications · first pickup \(day.firstPickup?.formatted(date: .omitted, time: .shortened) ?? "–")")
            log("  per app today (min · pickups · notifications):")
            for (app, use) in perApp.sorted(by: { $0.value.seconds > $1.value.seconds }).prefix(15) {
                log("    \(Int(use.seconds / 60)) min · \(use.pickups) · \(use.notifications)  \(app)")
            }
            log("  most notifications today:")
            for (app, use) in perApp.filter({ $0.value.notifications > 0 }).sorted(by: { $0.value.notifications > $1.value.notifications }).prefix(5) {
                log("    \(use.notifications)  \(app)")
            }
        }
        log("\(devices) device record(s) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
    }

    private func fetchInventory() async throws {
        lines += try await Self.inventory()
    }

    /// Off the main actor: FamilyActivityData and its results aren't Sendable, so only strings come back.
    nonisolated private static func inventory() async throws -> [String] {
        let data = FamilyActivityData.shared
        var lines: [String] = []
        let apps = try await data.installedApplications
        lines.append("\(apps.count) installed apps; with bundle id: \(apps.filter { $0.bundleIdentifier != nil }.count)")
        for app in apps.prefix(10) {
            lines.append("  \(app.localizedDisplayName ?? "?") [\(app.bundleIdentifier ?? "no bundle id")]")
        }
        let sites = try await data.visitedWebDomains
        lines.append("\(sites.count) visited web domains: \(sites.prefix(5).compactMap(\.domain).joined(separator: ", "))")
        let categories = try await data.activityCategories
        lines.append("\(categories.count) categories: \(categories.prefix(5).compactMap(\.localizedDisplayName).joined(separator: ", "))")
        return lines
    }
}
