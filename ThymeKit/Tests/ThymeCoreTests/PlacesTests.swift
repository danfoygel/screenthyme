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
}
