import Foundation
import Testing
@testable import ThymeCore

struct OutboxPendingTests {
    let kid = UUID()
    let firstSeen = Date(timeIntervalSince1970: 1_800_000_000)

    func item(_ identifier: String, match: UUID? = nil) -> TrackedItem {
        var item = TrackedItem(kidID: kid, kind: .app, identifier: identifier, firstSeen: firstSeen)
        item.match = match
        return item
    }

    @Test func aNewerVersionOfAnUploadedItemGoesUp() {
        let scanned = item("token:ab12")
        let matched = item("token:ab12", match: UUID())
        let uploaded: Set = [OutboxPending.version(of: scanned)]
        #expect(OutboxPending.pending([scanned, matched], uploaded: uploaded, key: OutboxPending.version).map(\.match) == [matched.match])
    }

    @Test func theLatestVersionGoesUpOnceAndAnOlderOneNeverReturns() {
        let scanned = item("token:ab12")
        let matched = item("token:ab12", match: UUID())
        #expect(OutboxPending.pending([scanned, matched], uploaded: [], key: OutboxPending.version).map(\.match) == [matched.match])
        // After the match went up, the older line isn't pending: it would undo the match.
        let uploaded: Set = [OutboxPending.version(of: matched)]
        #expect(OutboxPending.pending([scanned, matched], uploaded: uploaded, key: OutboxPending.version).isEmpty)
    }

    @Test func versionsAreStable() {
        #expect(OutboxPending.version(of: item("com.example.app")) == OutboxPending.version(of: item("com.example.app")))
        #expect(OutboxPending.version(of: item("com.example.app")) != OutboxPending.version(of: item("com.example.other")))
    }
}
