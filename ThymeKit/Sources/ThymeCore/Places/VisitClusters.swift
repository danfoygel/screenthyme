import Foundation

/// Visits to one spot no place covers yet: what a parent sees on the map, to name (PLAN.md §19).
public struct VisitCluster: Sendable, Hashable, Identifiable {
    /// Its earliest visit's, so it stays the same as visits are added.
    public var id: UUID
    public var latitude: Double
    public var longitude: Double
    /// Meters: the median of its visits' accuracies.
    public var accuracy: Double
    /// Oldest first.
    public var visits: [PlaceEvent]

    /// A fence for it, once named: wide enough for its visits, and for iOS to notice crossings.
    public var suggestedRadius: Double {
        let spread = visits.compactMap { visit -> Double? in
            guard let lat = visit.latitude, let lon = visit.longitude else { return nil }
            return Place.distance(latitude, longitude, lat, lon)
        }.max() ?? 0
        return min(max(Place.minimumRadius, accuracy, spread), Place.maximumRadius).rounded()
    }

    public var kids: Set<UUID> { Set(visits.compactMap(\.kidID)) }
    public var lastVisit: Date? { visits.map(\.at).max() }
}

/// Visits → the spots kids' phones stayed at. Two visits are one spot when their centers are within the larger of
/// their accuracies (`minimumDistance` at least): visits come with ±20 m to ±1 km.
public enum VisitClusters {
    /// Visits reported this precisely (Wi-Fi, often) still join a spot this close.
    public static let minimumDistance: Double = 50

    /// Each visit joins the nearest spot it's within reach of, the most precise visits first, so they make the
    /// centers and a vague visit can't pull two spots together. Visits inside `places` (allowing for their accuracy)
    /// are left out: they're named already. Most visited first.
    public static func build(_ visits: [PlaceEvent], excluding places: [Place] = []) -> [VisitCluster] {
        struct Spot {
            var visits: [PlaceEvent] = []
            /// Its most precise visit's: spots are seeded by the most precise first.
            var accuracy: Double
            var weight = 0.0
            var latitude = 0.0
            var longitude = 0.0

            mutating func add(_ visit: PlaceEvent, latitude lat: Double, longitude lon: Double, accuracy: Double) {
                // Weighted by precision, so a vague visit hardly moves the center.
                let w = 1 / pow(max(accuracy, 10), 2)
                latitude = (latitude * weight + lat * w) / (weight + w)
                longitude = (longitude * weight + lon * w) / (weight + w)
                weight += w
                visits.append(visit)
            }
        }
        let located = visits.compactMap { visit -> (PlaceEvent, Double, Double, Double)? in
            guard visit.kind == .visit, let lat = visit.latitude, let lon = visit.longitude,
                  let accuracy = visit.accuracy, accuracy >= 0 else { return nil }
            guard !places.contains(where: { $0.contains(latitude: lat, longitude: lon, accuracy: accuracy) }) else {
                return nil
            }
            return (visit, lat, lon, accuracy)
        }
        .sorted { ($0.3, $0.0.at, $0.0.id.uuidString) < ($1.3, $1.0.at, $1.0.id.uuidString) }

        var spots: [Spot] = []
        for (visit, lat, lon, accuracy) in located {
            let reach = spots.indices.compactMap { index -> (Int, Double)? in
                let distance = Place.distance(spots[index].latitude, spots[index].longitude, lat, lon)
                return distance <= max(accuracy, spots[index].accuracy, minimumDistance) ? (index, distance) : nil
            }
            if let (index, _) = reach.min(by: { $0.1 < $1.1 }) {
                spots[index].add(visit, latitude: lat, longitude: lon, accuracy: accuracy)
            } else {
                var spot = Spot(accuracy: accuracy)
                spot.add(visit, latitude: lat, longitude: lon, accuracy: accuracy)
                spots.append(spot)
            }
        }
        return spots.map { spot in
            let visits = spot.visits.sorted { ($0.at, $0.id.uuidString) < ($1.at, $1.id.uuidString) }
            let accuracies = spot.visits.compactMap(\.accuracy).sorted()
            return VisitCluster(id: visits[0].id, latitude: spot.latitude, longitude: spot.longitude,
                                accuracy: accuracies[accuracies.count / 2], visits: visits)
        }
        .sorted { ($0.visits.count, $0.lastVisit ?? .distantPast) > ($1.visits.count, $1.lastVisit ?? .distantPast) }
    }

    /// The place a visit was at, if any: the nearest whose fence it may be inside.
    public static func place(of visit: PlaceEvent, in places: [Place]) -> Place? {
        guard let lat = visit.latitude, let lon = visit.longitude else { return nil }
        return places.filter { $0.contains(latitude: lat, longitude: lon, accuracy: visit.accuracy ?? 0) }
            .min { Place.distance($0.latitude, $0.longitude, lat, lon) < Place.distance($1.latitude, $1.longitude, lat, lon) }
    }
}
