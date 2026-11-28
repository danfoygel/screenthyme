import Foundation
import Testing
@testable import ThymeCore

struct SyncStatusTests {
    let kid = UUID(), other = UUID()

    @Test func onlineShowsNothing() {
        #expect(SyncStatus.notice(syncedAt: at(13, 2), isOffline: false, kids: [kid], nearby: [], bluetoothOn: false) == nil)
    }

    @Test func offlineWithNobodyNearbyAndBluetoothOffSaysBoth() throws {
        let notice = try #require(SyncStatus.notice(syncedAt: at(13, 2), isOffline: true, kids: [kid], nearby: [],
                                                    bluetoothOn: false))
        #expect(notice.headline { _ in "1:02 PM" } == "Offline. Showing what synced at 1:02 PM.")
        #expect(notice.hint == "Turn on Bluetooth and open ScreenThyme on a kid's phone nearby to see it live.")
    }

    @Test func offlineWithBluetoothOnLeavesItOutOfTheHint() throws {
        let notice = try #require(SyncStatus.notice(syncedAt: at(13, 2), isOffline: true, kids: [kid], nearby: [],
                                                    bluetoothOn: true))
        #expect(notice.hint == "Open ScreenThyme on a kid's phone nearby to see it live.")
    }

    @Test func offlineWithTheKidNearbySaysOnlyTheFirstLine() throws {
        let notice = try #require(SyncStatus.notice(syncedAt: at(13, 2), isOffline: true, kids: [kid], nearby: [kid],
                                                    bluetoothOn: false))
        #expect(notice.hint == nil)
    }

    @Test func offlineWithOneOfTwoKidsNearbyStillHints() throws {
        let notice = try #require(SyncStatus.notice(syncedAt: at(13, 2), isOffline: true, kids: [kid, other],
                                                    nearby: [kid], bluetoothOn: true))
        #expect(notice.hint != nil)
    }

    @Test func neverSyncedSaysSo() throws {
        let notice = try #require(SyncStatus.notice(syncedAt: nil, isOffline: true, kids: [], nearby: [], bluetoothOn: true))
        #expect(notice.headline { _ in "" } == "Offline. Nothing has synced yet.")
    }
}
