import Foundation
import Testing
@testable import ThymeCore

struct PlacesTests {
    let home = Place(name: "Home", latitude: 0, longitude: 0)
    let school = Place(name: "School", latitude: 0.02, longitude: 0)

    func block(_ item: UUID, _ from: Date, _ to: Date, seconds: Double) -> UsageBlock {
        UsageBlock(itemID: item, start: from, end: to, seconds: seconds)
    }

    @Test func distanceAndFence() {
        // 0.02° of latitude is about 2.2 km.
        #expect(abs(Place.distance(0, 0, 0.02, 0) - 2224) < 5)
        #expect(home.contains(latitude: 0.001, longitude: 0))  // ~111 m
        #expect(!home.contains(latitude: 0.002, longitude: 0))  // ~222 m
        #expect(home.contains(latitude: 0.002, longitude: 0, accuracy: 100))
    }

    @Test func fenceCrossingsMakeStays() {
        let events = [
            PlaceEvent(kind: .enter, at: at(7, 0), place: home.id),
            PlaceEvent(kind: .enter, at: at(7, 10), place: home.id),  // repeated: ignored
            PlaceEvent(kind: .exit, at: at(7, 45), place: home.id),
            PlaceEvent(kind: .enter, at: at(8, 5), place: school.id),
            PlaceEvent(kind: .exit, at: at(9, 0), place: school.id),  // after `now`: not yet
        ]
        let stays = PlaceStays.build(events, places: [home, school], now: at(8, 30))
        #expect(stays == [
            PlaceStay(whereabouts: .place(home.id), start: at(7, 0), end: at(7, 45), isOpen: false),
            PlaceStay(whereabouts: .place(school.id), start: at(8, 5), end: at(8, 30), isOpen: true),
        ])
    }

    @Test func exitWithoutEntryIsIgnored() {
        let stays = PlaceStays.build([PlaceEvent(kind: .exit, at: at(7, 0), place: home.id)], places: [home], now: at(8, 0))
        #expect(stays.isEmpty)
    }

    @Test func visitsFillTheGapsAndFencesWin() {
        let events = [
            // Reported on arrival, then again with the departure.
            PlaceEvent(kind: .visit, at: at(15, 0), latitude: 0.1, longitude: 0.1, accuracy: 50),
            PlaceEvent(kind: .visit, at: at(15, 0, 20), departure: at(17, 0), latitude: 0.1, longitude: 0.1, accuracy: 50),
            PlaceEvent(kind: .enter, at: at(16, 0), place: home.id),
        ]
        let stays = PlaceStays.build(events, places: [home], now: at(18, 0))
        #expect(stays == [
            PlaceStay(whereabouts: .elsewhere, start: at(15, 0, 20), end: at(16, 0), isOpen: false),
            PlaceStay(whereabouts: .place(home.id), start: at(16, 0), end: at(18, 0), isOpen: true),
        ])
    }

    @Test func visitInsideAFenceCountsAsThePlace() {
        let events = [PlaceEvent(kind: .visit, at: at(12, 0), departure: at(13, 0), latitude: 0.0005, longitude: 0)]
        let stays = PlaceStays.build(events, places: [home, school], now: at(14, 0))
        #expect(stays == [PlaceStay(whereabouts: .place(home.id), start: at(12, 0), end: at(13, 0), isOpen: false)])
    }

    @Test func aVisitElsewhereEndsAFenceStayWhoseExitWasMissed() {
        let events = [
            PlaceEvent(kind: .enter, at: at(6, 0), place: home.id),
            // iOS saw the phone leave home, but the fence said nothing.
            PlaceEvent(kind: .visit, at: at(7, 46), departure: at(7, 46), latitude: 0, longitude: 0, accuracy: 10),
            PlaceEvent(kind: .visit, at: at(7, 57), departure: at(8, 7), latitude: 0.03, longitude: 0, accuracy: 50),
            PlaceEvent(kind: .visit, at: at(19, 43), latitude: 0.0001, longitude: 0, accuracy: 5),
        ]
        #expect(PlaceStays.build(events, places: [home], now: at(20, 0)) == [
            PlaceStay(whereabouts: .place(home.id), start: at(6, 0), end: at(7, 46), isOpen: false),
            PlaceStay(whereabouts: .elsewhere, start: at(7, 57), end: at(8, 7), isOpen: false),
            PlaceStay(whereabouts: .place(home.id), start: at(19, 43), end: at(20, 0), isOpen: true),
        ])
        // Without a visit at home saying when, the stay ends when the one elsewhere began.
        let away = [events[0], events[2]]
        #expect(PlaceStays.build(away, places: [home], now: at(9, 0)) == [
            PlaceStay(whereabouts: .place(home.id), start: at(6, 0), end: at(7, 57), isOpen: false),
            PlaceStay(whereabouts: .elsewhere, start: at(7, 57), end: at(8, 7), isOpen: false),
        ])
    }

    @Test func eitherFenceAPIIsEnough() {
        // Region monitoring saw the phone leave and come back; CLMonitor said nothing.
        var events = [
            PlaceEvent(kind: .enter, at: at(6, 0), place: home.id, source: .monitor),
            PlaceEvent(kind: .enter, at: at(6, 0, 5), place: home.id, source: .region),
            PlaceEvent(kind: .exit, at: at(7, 47), place: home.id, source: .region),
            PlaceEvent(kind: .enter, at: at(19, 43), place: home.id, source: .region),
        ]
        let expected = [
            PlaceStay(whereabouts: .place(home.id), start: at(6, 0), end: at(7, 47), isOpen: false),
            PlaceStay(whereabouts: .place(home.id), start: at(19, 43), end: at(20, 0), isOpen: true),
        ]
        #expect(PlaceStays.build(events, places: [home], now: at(20, 0)) == expected)
        // The same crossings from CLMonitor too, a few minutes late, change nothing.
        events += [PlaceEvent(kind: .exit, at: at(7, 50), place: home.id, source: .monitor),
                   PlaceEvent(kind: .enter, at: at(19, 46), place: home.id, source: .monitor)]
        #expect(PlaceStays.build(events, places: [home], now: at(20, 0)) == expected)
    }

    @Test func blocksAreSharedOutByStay() {
        let (game, video) = (UUID(), UUID())
        let stays = [
            PlaceStay(whereabouts: .place(home.id), start: at(7, 0), end: at(7, 30), isOpen: false),
            PlaceStay(whereabouts: .place(school.id), start: at(8, 0), end: at(9, 0), isOpen: false),
        ]
        let usage = PlaceStays.usage([
            block(game, at(7, 20), at(7, 40), seconds: 600),  // half at home, half on the way
            block(video, at(8, 10), at(8, 20), seconds: 300),
            block(video, at(8, 30), at(8, 30), seconds: 30),  // an instant: wholly at school
        ], stays: stays)
        #expect(usage[.place(home.id)] == [game: 300])
        #expect(usage[.unknown] == [game: 300])
        #expect(usage[.place(school.id)] == [video: 330])
    }

    @Test func removedAndUnknownFencesAreIgnored() {
        // Another phone's test fence, or a place since removed: its crossings say nothing about the family's places.
        let events = [
            PlaceEvent(kind: .enter, at: at(7, 0), place: UUID()),
            PlaceEvent(kind: .enter, at: at(8, 0), place: home.id),
        ]
        #expect(PlaceStays.build(events, places: [home], now: at(9, 0)) == [
            PlaceStay(whereabouts: .place(home.id), start: at(8, 0), end: at(9, 0), isOpen: true),
        ])
    }

    @Test func eachPhonesVisitsAreTheirOwn() {
        let (leo, mia) = (UUID(), UUID())
        // Two kids arrive together: two visits, though at the same time.
        let events = [
            PlaceEvent(kidID: leo, kind: .visit, at: at(8, 0), latitude: 0, longitude: 0, accuracy: 20),
            PlaceEvent(kidID: mia, kind: .visit, at: at(8, 0, 30), latitude: 0, longitude: 0, accuracy: 20),
            PlaceEvent(kidID: leo, kind: .visit, at: at(8, 0), departure: at(9, 0), latitude: 0, longitude: 0, accuracy: 20),
        ]
        let visits = PlaceStays.visits(events)
        #expect(visits.count == 2)
        #expect(visits.first { $0.kidID == leo }?.departure == at(9, 0))
        #expect(visits.first { $0.kidID == mia }?.departure == nil)
    }

    @Test func staysAreClippedToTheDay() {
        let stay = PlaceStay(whereabouts: .place(home.id), start: at(-2, 0), end: at(7, 0), isOpen: true)
        let day = DateInterval(start: at(0, 0), end: at(24, 0))
        #expect(PlaceStays.clip([stay], to: day) == [
            PlaceStay(whereabouts: .place(home.id), start: at(0, 0), end: at(7, 0), isOpen: true),
        ])
        #expect(PlaceStays.clip([stay], to: DateInterval(start: at(8, 0), end: at(9, 0))).isEmpty)
    }

    // MARK: - Visit clusters

    /// A visit about `meters` north of (0, 0).
    func visit(north meters: Double, accuracy: Double, at date: Date = at(12, 0), kid: UUID? = nil) -> PlaceEvent {
        PlaceEvent(kidID: kid, kind: .visit, at: date, departure: date.addingTimeInterval(1800),
                   latitude: meters / 111_195, longitude: 0, accuracy: accuracy)
    }

    @Test func visitsWithinTheirAccuracyAreOneSpot() {
        let visits = [
            visit(north: 0, accuracy: 30, at: at(8, 0)),
            visit(north: 40, accuracy: 80, at: at(9, 0)),  // within 80 m of the first
            visit(north: 25, accuracy: 10, at: at(10, 0)),  // within 50 m, the least distance
            visit(north: 400, accuracy: 60, at: at(11, 0)),  // another spot
        ]
        let clusters = VisitClusters.build(visits)
        #expect(clusters.count == 2)
        #expect(clusters[0].visits.map(\.at) == [at(8, 0), at(9, 0), at(10, 0)])
        #expect(clusters[0].id == visits[0].id)
        #expect(clusters[0].accuracy == 30)
        // Weighted by precision: nearest the ±10 m visit.
        let north = clusters[0].latitude * 111_195
        #expect(north > 15 && north < 25)
        #expect(clusters[1].visits.map(\.at) == [at(11, 0)])
        #expect(clusters[1].suggestedRadius == Place.minimumRadius)
    }

    @Test func aVagueVisitDoesntJoinTwoSpots() {
        let visits = [
            visit(north: 0, accuracy: 20),
            visit(north: 300, accuracy: 20),
            visit(north: 150, accuracy: 500),  // reaches both, but joins only one
        ]
        let clusters = VisitClusters.build(visits)
        #expect(clusters.count == 2)
        #expect(clusters.map(\.visits.count).sorted() == [1, 2])
    }

    @Test func visitsAtNamedPlacesAreLeftOut() {
        let visits = [visit(north: 50, accuracy: 20), visit(north: 2000, accuracy: 20)]
        let clusters = VisitClusters.build(visits, excluding: [home])
        #expect(clusters.map(\.id) == [visits[1].id])
        #expect(VisitClusters.place(of: visits[0], in: [home, school]) == home)
        #expect(VisitClusters.place(of: visits[1], in: [home, school]) == nil)
    }

    @Test func syntheticSchoolDayHasTwoVisitsHome() {
        let events = SyntheticScenario.schoolDay.placeEvents(kid: testKid, day: DayKey(dayStart, calendar: utc), calendar: utc)
        let visits = PlaceStays.visits(events)
        #expect(visits.count == 4)
        #expect(visits.last?.departure == nil)
        let clusters = VisitClusters.build(visits)
        #expect(clusters.map(\.visits.count) == [2, 1, 1])
    }
}

extension PlacesTests {
    @Test func aDayByLocation() {
        let (video, game) = (UUID(), UUID())
        let events = [
            // From the evening before: still home in the morning.
            PlaceEvent(kind: .visit, at: at(-3, 0), departure: at(7, 30), latitude: 0, longitude: 0, accuracy: 20),
            PlaceEvent(kind: .visit, at: at(8, 0), departure: at(15, 0), latitude: 0.05, longitude: 0, accuracy: 50),
            PlaceEvent(kind: .visit, at: at(16, 0), latitude: 0.0002, longitude: 0, accuracy: 20),
        ]
        let blocks = [
            block(video, at(7, 0), at(7, 20), seconds: 600),  // home
            block(game, at(7, 40), at(7, 50), seconds: 300),  // on the way
            block(video, at(12, 0), at(12, 10), seconds: 200),  // somewhere no place covers
            block(game, at(17, 0), at(18, 0), seconds: 1800),  // home again
        ]
        let day = LocationDay(events: events, places: [home], blocks: blocks,
                              day: DateInterval(start: at(0, 0), end: at(24, 0)), now: at(19, 0))
        #expect(day.stays.first == PlaceStay(whereabouts: .place(home.id), start: at(0, 0), end: at(7, 30), isOpen: false))
        #expect(day.stays.last == PlaceStay(whereabouts: .place(home.id), start: at(16, 0), end: at(19, 0), isOpen: true))
        #expect(day.locations().map(\.whereabouts) == [.place(home.id), .elsewhere, .unknown])
        #expect(day.locations().map(\.seconds) == [2400, 200, 300])
        #expect(day.locations(items: [video]).map(\.seconds) == [600, 200])
    }
}

extension PlacesTests {
    @Test func daysAddUp() {
        let video = UUID()
        func day(_ seconds: Double, at whereabouts: Whereabouts) -> LocationDay {
            var day = LocationDay(events: [], places: [], blocks: [], day: DateInterval(start: at(0, 0), end: at(24, 0)),
                                  now: at(24, 0))
            day.usage = [whereabouts: [video: seconds]]
            return day
        }
        let week = LocationDay.locations([day(60, at: .unknown), day(120, at: .place(home.id)), day(30, at: .unknown)])
        #expect(week.map(\.whereabouts) == [.place(home.id), .unknown])
        #expect(week.map(\.seconds) == [120, 90])
    }
}
