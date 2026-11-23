import Foundation
import Testing
@testable import ThymeCore

struct ParentUnlockTests {
    @Test func lastsItsMinutesByTheKidPhonesClock() {
        let unlock = ParentUnlock(by: "Parent A", at: at(15, 0))
        #expect(unlock.until == at(15, 15))
        #expect(unlock.isActive(at: at(15, 0)))
        #expect(unlock.isActive(at: at(15, 14, 59)))
        #expect(!unlock.isActive(at: at(15, 15)))
        // Setting the clock back only ends it.
        #expect(!unlock.isActive(at: at(14, 59)))
    }

    @Test func minutesAreClamped() {
        #expect(ParentUnlock(by: "A", at: at(15, 0), minutes: 0).until == at(15, 1))
        #expect(ParentUnlock(by: "A", at: at(15, 0), minutes: 600).until == at(16, 0))
    }

    @Test func controlsOpenOnlyBeforeTheFamilyKeyInTestModeOrWhileUnlocked() {
        let unlock = ParentUnlock(by: "Parent A", at: at(15, 0))
        #expect(ParentControls.areOpen(hasLinkKey: false, testMode: false, unlock: nil, now: at(15, 0)))
        #expect(ParentControls.areOpen(hasLinkKey: true, testMode: true, unlock: nil, now: at(15, 0)))
        #expect(!ParentControls.areOpen(hasLinkKey: true, testMode: false, unlock: nil, now: at(15, 0)))
        #expect(ParentControls.areOpen(hasLinkKey: true, testMode: false, unlock: unlock, now: at(15, 5)))
        #expect(!ParentControls.areOpen(hasLinkKey: true, testMode: false, unlock: unlock, now: at(15, 20)))
    }

    @Test func travelsInABundleAndPastTheSentFilter() throws {
        var bundle = LinkBundle()
        bundle.unlock = [.unlock(minutes: 15, by: "Parent A"), .state(until: at(15, 15)), .lock]
        #expect(!bundle.isEmpty)
        let decoded = try JSONDecoder.thyme.decode(LinkBundle.self, from: JSONEncoder.thyme.encode(bundle))
        #expect(decoded == bundle)
        var filter = LinkSentFilter()
        #expect(filter.unsent(bundle).unlock == bundle.unlock)
        #expect(filter.unsent(bundle).unlock == bundle.unlock)  // every time, like pairing
    }

    @Test func olderBundlesAndHeartbeatsStillOpen() throws {
        let old = try JSONDecoder.thyme.decode(LinkBundle.self, from: JSONEncoder.thyme.encode(LinkBundle()))
        #expect(old.unlock == nil)
        let beat = Heartbeat(kidID: testKid.id, at: at(15, 0), source: .nearby, authStatus: "approved",
                             activeActivities: [], expectedActivities: [], appVersion: "1", backlogCount: 0,
                             lastFireAt: nil, lastParentUnlock: ParentUnlock(by: "Parent A", at: at(15, 0)))
        let decoded = try JSONDecoder.thyme.decode(Heartbeat.self, from: JSONEncoder.thyme.encode(beat))
        #expect(decoded.lastParentUnlock == beat.lastParentUnlock)
    }
}
