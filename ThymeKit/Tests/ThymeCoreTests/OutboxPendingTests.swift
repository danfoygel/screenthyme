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
        let uploaded = [OutboxPending.version(of: scanned)]
        #expect(OutboxPending.pending([scanned, matched], uploaded: uploaded, key: OutboxPending.version).map(\.match) == [matched.match])
    }

    @Test func theLatestVersionGoesUpOnceAndAnOlderOneNeverReturns() {
        let scanned = item("token:ab12")
        let matched = item("token:ab12", match: UUID())
        #expect(OutboxPending.pending([scanned, matched], uploaded: [], key: OutboxPending.version).map(\.match) == [matched.match])
        // After the match went up, the older line isn't pending: it would undo the match.
        let uploaded = [OutboxPending.version(of: matched)]
        #expect(OutboxPending.pending([scanned, matched], uploaded: uploaded, key: OutboxPending.version).isEmpty)
    }

    @Test func aVersionThatComesBackGoesUpAgain() {
        // A token matched, then a scan took it, then a pick gave it back: the last line is the second one again.
        var matched = item("token:ab12", match: UUID())
        matched.tokenData = Data("token".utf8)
        var dropped = matched
        dropped.tokenData = nil
        let lines = [matched, dropped, matched]
        let uploaded = [OutboxPending.version(of: matched), OutboxPending.version(of: dropped)]
        #expect(OutboxPending.pending(lines, uploaded: uploaded, key: OutboxPending.version).map(\.tokenData) == [matched.tokenData])
        // Once it's gone up again, it's done.
        #expect(OutboxPending.pending(lines, uploaded: uploaded + [OutboxPending.version(of: matched)],
                                      key: OutboxPending.version).isEmpty)
    }

    @Test func idLedgersListEachRecordOnce() {
        let lines = [item("com.example.app"), item("com.example.other")]
        #expect(OutboxPending.pending(lines, uploaded: [lines[0].id], key: \.id).map(\.id) == [lines[1].id])
    }

    @Test func versionsAreStable() {
        #expect(OutboxPending.version(of: item("com.example.app")) == OutboxPending.version(of: item("com.example.app")))
        #expect(OutboxPending.version(of: item("com.example.app")) != OutboxPending.version(of: item("com.example.other")))
    }
}
