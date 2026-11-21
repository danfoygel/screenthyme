import CoreLocation
import Foundation
import Observation
import ThymeCore
import UIKit

/// The location test on a kid's phone (PLAN.md §19): geofences around the places marked here, plus iOS's visits,
/// written to App Group `Places/events.jsonl`. Each place is watched by both of iOS's geofence APIs, `CLMonitor` and
/// the older region monitoring, since `CLMonitor` once missed a whole day's crossings. iOS watches both itself, on Wi-Fi and cell towers, and wakes or
/// relaunches the app only at a crossing or a visit, so there's no polling and no location background mode.
/// Nothing leaves the phone yet.
@MainActor @Observable final class PlaceWatcher: NSObject, CLLocationManagerDelegate {
    static let shared = PlaceWatcher()

    private static let enabledKey = "placesTest"
    private static let monitorName = "places"

    private(set) var places: [Place] = AppGroup.load([Place].self, from: AppGroup.placesURL) ?? []
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    /// What CoreLocation says is holding it back, if anything.
    private(set) var problem: String?
    /// Bumped at each change to the events file, so views showing `events` redraw.
    private(set) var revision = 0
    /// What iOS's fence monitor believes about each place now (`CLMonitor.record(for:)`), whatever reached `events`.
    private(set) var fences: [UUID: Fence] = [:]
    /// The older API's last answer for each place (`didDetermineState`), and when it came: it gives no date of its own.
    private(set) var regions: [UUID: Fence] = [:]

    struct Fence: Hashable {
        var state: String
        var since: Date
    }

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    /// For heartbeats (`DevicePermission.location`): fences and visits need Always and Precise Location.
    /// Nil while places aren't watched, so parents aren't told about a permission the phone doesn't use.
    var permission: PermissionState? {
        guard isEnabled else { return nil }
        return switch authorization {
        case .notDetermined: .notAsked
        case .authorizedAlways: manager.accuracyAuthorization == .fullAccuracy ? .allowed : .denied
        default: .denied
        }
    }

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var session: CLServiceSession?
    @ObservationIgnored private var monitor: CLMonitor?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var locating: CheckedContinuation<Fix, Error>?

    struct Fix: Sendable {
        var latitude: Double
        var longitude: Double
        var accuracy: Double
    }

    override private init() {
        super.init()
        manager.delegate = self
        authorization = manager.authorizationStatus
    }

    /// At every launch, background ones included: iOS relaunches the app for a crossing or a visit, and delivers it
    /// only once the monitor and the visit delegate are set up again.
    func start() {
        guard isEnabled, tasks.isEmpty else { return }
        log("started, \(UIApplication.shared.applicationState == .background ? "in the background" : "in the foreground"), "
            + "location \(authorization.label)\(manager.accuracyAuthorization == .fullAccuracy ? "" : ", not precise")")
        if authorization == .notDetermined || authorization == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
        // Since iOS 18, CLMonitor events reach a backgrounded app only while it holds a session.
        let session = CLServiceSession(authorization: .always)
        self.session = session
        manager.startMonitoringVisits()
        syncRegions()
        tasks = [
            Task { await self.watchFences() },
            Task {
                do {
                    for try await diagnostic in session.diagnostics {
                        let problem = Self.describe(diagnostic)
                        if problem != self.problem { self.log("session: \(problem ?? "fine")") }
                        self.problem = problem
                    }
                } catch {}
            },
        ]
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        log("watching places \(enabled ? "on" : "off")")
        if enabled {
            start()
        } else {
            tasks.forEach { $0.cancel() }
            tasks = []
            manager.stopMonitoringVisits()
            session = nil
            problem = nil
            if let monitor {
                Task { for id in await monitor.identifiers { await monitor.remove(id) } }
            }
            manager.monitoredRegions.forEach(manager.stopMonitoring)
        }
    }

    /// A fence around where the phone is now.
    func markHere(name: String) async throws {
        let fix = try await locate()
        // A fence smaller than the fix's own error would flicker.
        let place = Place(name: name, latitude: fix.latitude, longitude: fix.longitude,
                          radius: max(Place.defaultRadius, fix.accuracy * 2))
        places.append(place)
        save()
        log("marked \(name), \(Int(place.radius)) m")
        if let monitor { await sync(monitor) }
        syncRegions()
    }

    func remove(_ place: Place) {
        places.removeAll { $0.id == place.id }
        save()
        log("removed \(place.name)")
        syncRegions()
        if let monitor { Task { await monitor.remove(place.id.uuidString) } }
    }

    var events: [PlaceEvent] {
        _ = revision
        return AppGroup.placeEvents.readAll()
    }

    func clearEvents() {
        try? FileManager.default.removeItem(at: AppGroup.placeEvents.url)
        revision += 1
    }

    // MARK: - Fences

    private func watchFences() async {
        let monitor = await CLMonitor(Self.monitorName)
        self.monitor = monitor
        await sync(monitor)
        await refreshFences()
        log("monitor opened: " + places.map { place in
            fences[place.id].map { "\(place.name) \($0.state) since \(Self.stamp($0.since))" } ?? "\(place.name) not monitored"
        }.joined(separator: "; "))
        do {
            for try await event in await monitor.events {
                record(event)
                await refreshFences()
            }
            log("monitor events ended")
        } catch {
            problem = "Geofences stopped: \(error.localizedDescription)"
            log("monitor events failed: \(error)")
        }
    }

    /// Reads the monitor's own record of each fence.
    func refreshFences() async {
        guard let monitor else { return }
        var fences: [UUID: Fence] = [:]
        for place in places {
            if let event = await monitor.record(for: place.id.uuidString)?.lastEvent {
                fences[place.id] = Fence(state: Self.label(event.state), since: event.date)
            }
        }
        self.fences = fences
    }

    /// Every launch, monitor answer and problem, for when fences go quiet (PLAN.md §19).
    private func log(_ line: String) {
        let url = AppGroup.placeDiagnosticsURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Kept small: the older half goes once it passes 256 KB.
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 256_000,
           let text = try? String(contentsOf: url, encoding: .utf8) {
            try? String(text.dropFirst(text.count / 2)).write(to: url, atomically: true, encoding: .utf8)
        }
        let data = Data("\(Self.stamp(Date())) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
        revision += 1
    }

    var diagnostics: [String] {
        _ = revision
        let text = (try? String(contentsOf: AppGroup.placeDiagnosticsURL, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").suffix(60).map(String.init)
    }

    private static func stamp(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute().second())
    }

    static func label(_ state: CLMonitor.Event.State) -> String {
        switch state {
        case .unknown: "unknown"
        case .satisfied: "inside"
        case .unsatisfied: "outside"
        case .unmonitored: "not monitored"
        @unknown default: "state \(state.rawValue)"
        }
    }

    /// Makes the monitor's fences match `places`.
    private func sync(_ monitor: CLMonitor) async {
        let wanted = Dictionary(places.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        let existing = Set(await monitor.identifiers)
        for id in existing where wanted[id] == nil {
            await monitor.remove(id)
        }
        for (id, place) in wanted where !existing.contains(id) {
            let center = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
            await monitor.add(CLMonitor.CircularGeographicCondition(center: center, radius: place.radius), identifier: id)
        }
    }

    /// Makes the older API's regions match `places`, then asks it where the phone is for each.
    private func syncRegions() {
        let wanted = Set(places.map(\.id.uuidString))
        for region in manager.monitoredRegions where !wanted.contains(region.identifier) {
            manager.stopMonitoring(for: region)
        }
        let existing = Set(manager.monitoredRegions.map(\.identifier))
        for place in places where !existing.contains(place.id.uuidString) {
            let center = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
            let region = CLCircularRegion(center: center, radius: min(place.radius, manager.maximumRegionMonitoringDistance),
                                          identifier: place.id.uuidString)
            region.notifyOnEntry = true
            region.notifyOnExit = true
            manager.startMonitoring(for: region)
            log("region added: \(place.name)")
        }
        for region in manager.monitoredRegions {
            manager.requestState(for: region)
        }
    }

    /// The older API's answer, at a crossing or when asked: a crossing when it differs from its last one.
    private func record(region identifier: String, state: CLRegionState) {
        guard let place = UUID(uuidString: identifier) else { return }
        let label = switch state {
        case .inside: "inside"
        case .outside: "outside"
        default: "unknown"
        }
        let name = places.first { $0.id == place }?.name ?? "fence \(identifier.prefix(8))"
        log("region: \(name) \(label)")
        regions[place] = Fence(state: label, since: Date())
        let kind: PlaceEvent.Kind
        switch state {
        case .inside: kind = .enter
        case .outside: kind = .exit
        default: return
        }
        if events.last(where: { $0.place == place && $0.source == .region })?.kind == kind { return }
        append(PlaceEvent(kind: kind, at: Date(), place: place, source: .region))
    }

    private func record(_ event: CLMonitor.Event) {
        let name = places.first { $0.id.uuidString == event.identifier }?.name ?? "fence \(event.identifier.prefix(8))"
        let issue = Self.describe(event)
        log("event: \(name) \(Self.label(event.state)) at \(Self.stamp(event.date))\(issue.map { " (\($0))" } ?? "")")
        if let issue {
            problem = "Geofence: \(issue)"
        }
        guard let place = UUID(uuidString: event.identifier) else { return }
        let kind: PlaceEvent.Kind
        switch event.state {
        case .satisfied: kind = .enter
        case .unsatisfied: kind = .exit
        default: return
        }
        // A relaunch can hand over the last event again.
        if let last = events.last(where: { $0.place == place && ($0.source ?? .monitor) == .monitor }),
           last.kind == kind, last.at == event.date { return }
        append(PlaceEvent(kind: kind, at: event.date, place: place, source: .monitor))
    }

    // MARK: - Visits and one-off fixes (CLLocationManagerDelegate, on the main thread: the manager was made there)

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let (arrival, departure) = (visit.arrivalDate, visit.departureDate)
        let (latitude, longitude, accuracy) = (visit.coordinate.latitude, visit.coordinate.longitude, visit.horizontalAccuracy)
        MainActor.assumeIsolated {
            // iOS says distantPast for an arrival it didn't see, and distantFuture while the phone is still there.
            let at = arrival == .distantPast ? (departure == .distantFuture ? Date() : departure) : arrival
            append(PlaceEvent(kind: .visit, at: at, departure: departure == .distantFuture ? nil : departure,
                              latitude: latitude, longitude: longitude, accuracy: accuracy))
        }
    }

    /// At each crossing of a region, and when asked (`requestState`).
    nonisolated func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState,
                                     for region: CLRegion) {
        let identifier = region.identifier
        MainActor.assumeIsolated { record(region: identifier, state: state) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?,
                                     withError error: any Error) {
        let (identifier, text) = (region?.identifier ?? "?", error.localizedDescription)
        MainActor.assumeIsolated {
            log("region \(identifier.prefix(8)) failed: \(text)")
            problem = "Region: \(text)"
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            if status != authorization { log("location: \(status.label)") }
            authorization = status
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let fix = Fix(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                      accuracy: location.horizontalAccuracy)
        MainActor.assumeIsolated {
            locating?.resume(returning: fix)
            locating = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        MainActor.assumeIsolated {
            locating?.resume(throwing: error)
            locating = nil
        }
    }

    private func locate() async throws -> Fix {
        locating?.resume(throwing: CancellationError())
        manager.desiredAccuracy = kCLLocationAccuracyBest
        return try await withCheckedThrowingContinuation { continuation in
            locating = continuation
            manager.requestLocation()
        }
    }

    // MARK: -

    private func append(_ event: PlaceEvent) {
        try? AppGroup.placeEvents.append(event)
        revision += 1
        EnergyMeter.record(.app, isCallback: true)
    }

    private func save() {
        try? FileManager.default.createDirectory(at: AppGroup.placesURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        AppGroup.save(places, to: AppGroup.placesURL)
    }

    private static func describe(_ diagnostic: CLServiceSession.Diagnostic) -> String? {
        if diagnostic.authorizationDeniedGlobally { return "Location Services are off" }
        if diagnostic.authorizationRestricted { return "Location is restricted (Screen Time or a profile)" }
        if diagnostic.authorizationDenied { return "Location is off for ScreenThyme" }
        if diagnostic.alwaysAuthorizationDenied { return "Location is “While Using”, not “Always”" }
        if diagnostic.insufficientlyInUse { return "Waiting to be opened" }
        if diagnostic.authorizationRequestInProgress { return "Asking for location" }
        return nil
    }

    private static func describe(_ event: CLMonitor.Event) -> String? {
        if event.authorizationDenied { return "location is off" }
        if event.authorizationRestricted { return "location is restricted" }
        if event.accuracyLimited { return "Precise Location is off" }
        if event.conditionLimitExceeded { return "too many fences (20 at most)" }
        if event.serviceSessionRequired { return "no location session" }
        if event.persistenceUnavailable { return "iOS can't save the fences" }
        return nil
    }
}

extension CLAuthorizationStatus {
    var label: String {
        switch self {
        case .notDetermined: "not asked"
        case .restricted: "restricted"
        case .denied: "off"
        case .authorizedWhenInUse: "while using"
        case .authorizedAlways: "always"
        @unknown default: "unknown"
        }
    }
}
