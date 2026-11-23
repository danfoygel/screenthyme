import CoreLocation
import Foundation
import Observation
import ThymeCore
import UIKit

/// The location test on a kid's phone (PLAN.md §19): geofences around the places marked here (region monitoring:
/// `CLMonitor` missed or delayed every crossing in the comparison), plus iOS's visits, written to App Group
/// `Places/events.jsonl`. iOS watches both itself, on Wi-Fi and cell towers, and wakes or relaunches the app only at a
/// crossing or a visit, so there's no polling and no location background mode. Nothing leaves the phone yet.
@MainActor @Observable final class PlaceWatcher: NSObject, CLLocationManagerDelegate {
    static let shared = PlaceWatcher()

    private static let enabledKey = "placesTest"
    /// `CLMonitor`'s name for the fences it held before it was dropped (`retireMonitor`).
    private static let retiredMonitorName = "places"
    private static let retiredMonitorKey = "placesMonitorRetired"

    private(set) var places: [Place] = AppGroup.load([Place].self, from: AppGroup.placesURL) ?? []
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    /// What CoreLocation says is holding it back, if anything.
    private(set) var problem: String?
    /// Bumped at each change to the events file, so views showing `events` redraw.
    private(set) var revision = 0
    /// Region monitoring's last answer for each place (`didDetermineState`), and when it came: it gives no date.
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
    @ObservationIgnored private var started = false
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
    /// to this delegate.
    func start() {
        guard isEnabled, !started else { return }
        started = true
        log("started, \(UIApplication.shared.applicationState == .background ? "in the background" : "in the foreground"), "
            + "location \(authorization.label)\(manager.accuracyAuthorization == .fullAccuracy ? "" : ", not precise")")
        if authorization == .notDetermined || authorization == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
        manager.startMonitoringVisits()
        syncRegions()
        retireMonitor()
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        log("watching places \(enabled ? "on" : "off")")
        if enabled {
            start()
        } else {
            started = false
            manager.stopMonitoringVisits()
            problem = nil
            ownRegions.forEach(manager.stopMonitoring)
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
        syncRegions()
    }

    func remove(_ place: Place) {
        places.removeAll { $0.id == place.id }
        save()
        log("removed \(place.name)")
        syncRegions()
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

    /// Removes the fences `CLMonitor` held before it was dropped, once: iOS keeps them across launches.
    private func retireMonitor() {
        guard !UserDefaults.standard.bool(forKey: Self.retiredMonitorKey) else { return }
        Task {
            let monitor = await CLMonitor(Self.retiredMonitorName)
            let identifiers = await monitor.identifiers
            for id in identifiers { await monitor.remove(id) }
            UserDefaults.standard.set(true, forKey: Self.retiredMonitorKey)
            log("CLMonitor retired: \(identifiers.count) fence(s) removed")
        }
    }

    /// Every launch, region answer and problem, for when fences go quiet (PLAN.md §19).
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

    /// Regions this app made: named by a place's id. iOS lists others among them too (`CLMonitor`'s own, once),
    /// and touching those broke them.
    private var ownRegions: [CLRegion] {
        manager.monitoredRegions.filter { UUID(uuidString: $0.identifier) != nil }
    }

    /// Makes our regions match `places`, then asks where the phone is for each.
    private func syncRegions() {
        let wanted = Set(places.map(\.id.uuidString))
        for region in ownRegions where !wanted.contains(region.identifier) {
            manager.stopMonitoring(for: region)
        }
        let existing = Set(ownRegions.map(\.identifier))
        for place in places where !existing.contains(place.id.uuidString) {
            let center = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
            let region = CLCircularRegion(center: center, radius: min(place.radius, manager.maximumRegionMonitoringDistance),
                                          identifier: place.id.uuidString)
            region.notifyOnEntry = true
            region.notifyOnExit = true
            manager.startMonitoring(for: region)
            log("region added: \(place.name)")
        }
        for region in ownRegions {
            manager.requestState(for: region)
        }
    }

    /// Region monitoring's answer, at a crossing or when asked: a crossing when it differs from its last one.
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
            log("region \(identifier) failed: \(text)")
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
