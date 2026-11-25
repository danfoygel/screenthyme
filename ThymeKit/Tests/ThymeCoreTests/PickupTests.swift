import Foundation
import Testing
@testable import ThymeCore

struct PickupTests {
    let messages = UUID()
    let maps = UUID()
    let news = UUID()

    func report(updatedAt: Date = at(12, 0), notifications: Int = 3) -> PickupReport {
        PickupReport(kidID: testKid.id, day: testDay, updatedAt: updatedAt, hours: [
            .init(start: at(11, 0), pickupsWithoutApp: 2, firstPickup: at(11, 6), apps: [
                .init(itemID: messages, bundleID: "messages", pickups: 4, notifications: notifications),
                .init(itemID: news, bundleID: "news", pickups: 0, notifications: 1),
            ]),
            .init(start: at(9, 0), pickupsWithoutApp: 1, firstPickup: at(9, 10), apps: [
                .init(itemID: messages, bundleID: "messages", pickups: 1, notifications: 2),
                .init(itemID: maps, bundleID: "maps", pickups: 2, notifications: 0),
                .init(itemID: UUID(), bundleID: "other", pickups: 0, notifications: 0),
            ]),
            // Notifications on the lock screen, no pickup: nothing Apple counts.
            .init(start: at(3, 0), pickupsWithoutApp: 0, firstPickup: nil, apps: []),
        ])
    }

    @Test func totalsTheDay() {
        let report = report()
        #expect(report.hours.map(\.start) == [at(9, 0), at(11, 0)])
        #expect(report.hours[0].apps.count == 2)  // the app with neither is left out
        #expect(report.pickups == 10)
        #expect(report.pickupsWithoutApp == 3)
        #expect(report.notifications == 6)
        #expect(report.firstPickup == at(9, 10))
        #expect(report.apps.map(\.itemID) == [messages, maps, news])
        #expect(report.apps[0] == .init(itemID: messages, bundleID: "messages", pickups: 5, notifications: 5))
    }

    @Test func oneRecordPerKidAndDay() {
        #expect(report(updatedAt: at(9, 0)).id == report(updatedAt: at(17, 0)).id)
        let tomorrow = PickupReport(kidID: testKid.id, day: testDay.adding(days: 1, calendar: utc), updatedAt: at(9, 0), hours: [])
        #expect(tomorrow.id != report().id)
    }

    @Test func outboxQueuesOnlyChanges() {
        var outbox = PickupOutbox()
        let first = outbox.record(report(updatedAt: at(12, 0)))
        let same = outbox.record(report(updatedAt: at(12, 1)))
        #expect(first && !same)
        #expect(outbox.pending.map(\.updatedAt) == [at(12, 0)])
        let changed = outbox.record(report(updatedAt: at(12, 2), notifications: 4))
        #expect(changed)
        #expect(outbox.pending.map(\.updatedAt) == [at(12, 2)])  // replaces the day's queued report
    }

    @Test func outboxKeepsWhatChangedDuringAnUpload() {
        var outbox = PickupOutbox()
        outbox.record(report(updatedAt: at(12, 0)))
        let uploading = outbox.pending
        outbox.record(report(updatedAt: at(12, 1), notifications: 9))
        outbox.markUploaded(uploading)
        #expect(outbox.pending.map(\.updatedAt) == [at(12, 1)])
        outbox.markUploaded(outbox.pending)
        #expect(outbox.pending.isEmpty)
    }

    @Test func outboxKeepsYesterdaysUntilUploaded() {
        var outbox = PickupOutbox()
        outbox.record(report())
        let tomorrow = PickupReport(kidID: testKid.id, day: testDay.adding(days: 1, calendar: utc), updatedAt: at(24, 5),
                                    hours: [.init(start: at(24, 0), pickupsWithoutApp: 1, firstPickup: at(24, 4), apps: [])])
        outbox.record(tomorrow)
        #expect(outbox.pending.count == 2)
    }
}
