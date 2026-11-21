import Foundation

/// A place a kid's phone watches with a geofence: home, school (PLAN.md §19).
public struct Place: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var latitude: Double
    public var longitude: Double
    /// Meters. iOS doesn't notice crossings of fences much smaller than about 100 m.
    public var radius: Double

    public static let defaultRadius: Double = 150

    public init(id: UUID = UUID(), name: String, latitude: Double, longitude: Double, radius: Double = Place.defaultRadius) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
    }

    /// Whether a point (with its accuracy, in meters) may be inside the fence.
    public func contains(latitude: Double, longitude: Double, accuracy: Double = 0) -> Bool {
        Place.distance(self.latitude, self.longitude, latitude, longitude) <= radius + max(accuracy, 0)
    }

    /// Great-circle distance in meters (haversine).
    public static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let radians = Double.pi / 180
        let dLat = (lat2 - lat1) * radians
        let dLon = (lon2 - lon1) * radians
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * radians) * cos(lat2 * radians) * sin(dLon / 2) * sin(dLon / 2)
        return 6_371_000 * 2 * atan2(a.squareRoot(), (1 - a).squareRoot())
    }
}

/// What iOS told the kid app about where the phone is: a geofence crossing or a visit (PLAN.md §19).
/// Kept on the phone only; never in the journal, whose notes go into bug reports.
public struct PlaceEvent: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// The phone is inside `place`'s fence (also iOS's first answer after a fence is added).
        case enter
        case exit
        /// iOS noticed the phone staying somewhere, from `at` until `departure` (nil while still there).
        /// It reports each visit twice: on arrival, then again with the departure.
        case visit
    }

    /// Which of iOS's two geofence APIs reported a crossing; they run side by side to compare (PLAN.md §19).
    public enum Source: String, Codable, Sendable {
        /// `CLMonitor` (iOS 17).
        case monitor
        /// `CLLocationManager` region monitoring, the older API.
        case region
    }

    public var id: UUID
    public var kind: Kind
    /// When it happened, by iOS's account.
    public var at: Date
    /// When the app heard about it: how late iOS is.
    public var observedAt: Date
    public var place: UUID?
    /// For crossings; nil in events from before the comparison, which were all `monitor`'s.
    public var source: Source?
    public var departure: Date?
    public var latitude: Double?
    public var longitude: Double?
    /// Meters.
    public var accuracy: Double?

    public init(id: UUID = UUID(), kind: Kind, at: Date, observedAt: Date = Date(), place: UUID? = nil,
                source: Source? = nil, departure: Date? = nil, latitude: Double? = nil, longitude: Double? = nil,
                accuracy: Double? = nil) {
        self.id = id
        self.kind = kind
        self.at = at
        self.observedAt = observedAt
        self.place = place
        self.source = source
        self.departure = departure
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
    }

    public var delay: TimeInterval { observedAt.timeIntervalSince(departure ?? at) }
}
