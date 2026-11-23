import CoreLocation
import Foundation
import MapKit
import ThymeCore

/// The family's places and where kids' phones were, on parents' phones (PLAN.md §19).
extension AppModel {
    /// Days of visits the Places map shows.
    static let placesMapDays = 60

    /// Saves the family's places; kids' phones fetch them by name (`KidSync`) and fence them.
    func save(places: [Place]) async {
        // The whole list is saved: one built from a mirror still re-fetching could drop places.
        guard !refuseWhileRebuilding() else { return }
        let record = FamilyPlaces(places: places)
        data.ingest(IngestBatch(familyPlaces: [record]))
        guard let store else { return }
        do { try await PendingSaves.save([record], to: store) } catch { show(error) }
    }

    /// The visits of one kid's phone (or every kid's) over the map's days, one event per visit.
    func visits(kid: UUID?, now: Date = Date()) -> [PlaceEvent] {
        let today = DayKey(now)
        let kids = kid.map { [$0] } ?? data.sortedKids.map(\.id)
        return PlaceStays.visits(kids.flatMap {
            data.placeEvents(kid: $0, from: today.adding(days: -Self.placesMapDays), through: today)
        })
    }

    /// The kid's day by location; nil when the phone said nothing about where it was that week (location is off).
    func locationDay(kid: UUID, day: DayKey, timeline: DayTimeline? = nil, now: Date = Date()) -> LocationDay? {
        let events = data.placeEvents(kid: kid, from: day.adding(days: -LocationDay.lookbackDays), through: day)
        guard !events.isEmpty else { return nil }
        let blocks = (timeline ?? self.timeline(kid: kid, day: day).timeline).blocks
        return LocationDay(events: events, places: data.places, blocks: blocks,
                           day: DateInterval(start: day.start(), end: day.end()), now: now)
    }

    /// Whether the kid's phone watches where it is: its heartbeat reports location access only then.
    func tracksLocation(_ kid: UUID) -> Bool {
        data.heartbeats[kid]?.location != nil
    }

    func name(of whereabouts: Whereabouts) -> String {
        switch whereabouts {
        case let .place(id): data.places.first { $0.id == id }?.name ?? "Removed place"
        case .elsewhere: "Other locations"
        case .unknown: "While moving"
        }
    }
}

extension Whereabouts {
    var systemImage: String {
        switch self {
        case .place: "mappin.circle.fill"
        case .elsewhere: "mappin.and.ellipse"
        case .unknown: "figure.walk.motion"
        }
    }
}

/// Street addresses for spots on the map, from Apple's reverse geocoding: looked up once per spot per launch.
@MainActor enum Addresses {
    private static var cache: [String: String] = [:]

    static func lookUp(latitude: Double, longitude: Double) async -> String? {
        let key = String(format: "%.4f,%.4f", latitude, longitude)
        if let cached = cache[key] { return cached }
        guard let request = MKReverseGeocodingRequest(location: CLLocation(latitude: latitude, longitude: longitude)),
              let item = try? await request.mapItems.first else { return nil }
        let address = item.address?.shortAddress ?? item.addressRepresentations?.cityWithContext ?? item.name
        if let address { cache[key] = address }
        return address
    }
}
