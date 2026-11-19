import CoreLocation
import Foundation
import Observation
import ThymeCore

/// The location test on a kid's phone (PLAN.md §19): geofences around the places marked here, plus iOS's visits,
/// written to App Group `Places/events.jsonl`. iOS watches both itself, on Wi-Fi and cell towers, and wakes or
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

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

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
        if authorization == .notDetermined || authorization == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
        // Since iOS 18, CLMonitor events reach a backgrounded app only while it holds a session.
        let session = CLServiceSession(authorization: .always)
        self.session = session
        manager.startMonitoringVisits()
        tasks = [
            Task { await self.watchFences() },
            Task {
                do {
                    for try await diagnostic in session.diagnostics {
                        self.problem = Self.describe(diagnostic)
                    }
                } catch {}
            },
        ]
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
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
        if let monitor { await sync(monitor) }
    }

    func remove(_ place: Place) {
        places.removeAll { $0.id == place.id }
        save()
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
        do {
            for try await event in await monitor.events {
                record(event)
            }
        } catch {
            problem = "Geofences stopped: \(error.localizedDescription)"
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

    private func record(_ event: CLMonitor.Event) {
        if let issue = Self.describe(event) {
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
        if let last = events.last(where: { $0.place == place }), last.kind == kind, last.at == event.date { return }
        append(PlaceEvent(kind: kind, at: event.date, place: place))
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

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated { authorization = status }
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
