import Foundation
import Testing
@testable import ThymeCore

struct LinkTests {
    let key = LinkKey.generate(now: at(8, 0))
    let parentHello = LinkHello(role: .parent, kidID: nil, name: "Parent A", sentAt: at(8, 0))
    let kidHello = LinkHello(role: .kid, kidID: testKid.id, name: "Emma", sentAt: at(8, 0))
    let grantBundle: LinkBundle = {
        var bundle = LinkBundle()
        let request = TimeRequest(kidID: testKid.id, itemID: nil, reason: .blocked, minutes: 15, at: at(9, 0))
        bundle.grants = [TimeGrant(request: request, approved: true, minutes: 15, at: at(9, 1), by: "Parent A")]
        return bundle
    }()

    /// Exchanges hellos, with fresh nonces as on a real connection; returns both sessions ready to send.
    func connect() throws -> (kid: LinkSession, parent: LinkSession) {
        var kidHello = kidHello
        var parentHello = parentHello
        kidHello.nonce = LinkHello.makeNonce()
        parentHello.nonce = LinkHello.makeNonce()
        var kid = LinkSession(key: key, side: .listener, hello: kidHello)
        var parent = LinkSession(key: key, side: .dialer, hello: parentHello)
        let kidStart = try kid.start()
        let parentStart = try parent.start()
        #expect(try parent.receive(kidStart) == [.hello(kidHello)])
        #expect(try kid.receive(parentStart) == [.hello(parentHello)])
        return (kid, parent)
    }

    @Test func bundlesFlowBothWays() throws {
        var (kid, parent) = try connect()
        #expect(kid.isReady && parent.isReady)
        #expect(!parent.isVerified)

        var usage = LinkBundle()
        usage.kids = [testKid]
        usage.samples = (0..<500).map { index in
            UsageSample(id: UUID(), kidID: testKid.id, itemID: UUID(), day: testDay, start: at(9, index % 60),
                        end: at(9, index % 60, 30), seconds: 30)
        }
        #expect(try parent.receive(kid.send(usage)) == [.bundle(usage)])
        #expect(parent.isVerified)
        #expect(try kid.receive(parent.send(grantBundle)) == [.bundle(grantBundle)])
        #expect(parent.peer?.kidID == testKid.id && kid.peer?.role == .parent)
    }

    @Test func framesSplitAndJoinedAcrossReads() throws {
        var (kid, parent) = try connect()
        let bytes = try parent.send(grantBundle) + parent.send(LinkBundle()) + parent.send(grantBundle)
        var events: [LinkSession.Event] = []
        for start in stride(from: 0, to: bytes.count, by: 7) {
            events += try kid.receive(bytes.subdata(in: start..<min(start + 7, bytes.count)))
        }
        #expect(events == [.bundle(grantBundle), .bundle(LinkBundle()), .bundle(grantBundle)])
    }

    @Test func anotherFamilyCantSayHello() throws {
        let stranger = LinkKey.generate()
        var parent = LinkSession(key: key, side: .dialer, hello: parentHello)
        let strangerHello = try LinkSession(key: stranger, side: .listener, hello: kidHello).start()
        #expect(throws: LinkSession.Failure.notAuthentic) { try parent.receive(strangerHello) }
    }

    @Test func replayedFramesDontOpen() throws {
        var (kid, parent) = try connect()
        let frame = try parent.send(grantBundle)
        _ = try kid.receive(frame)
        // The same frame again, in this connection: the counter moved on.
        #expect(throws: LinkSession.Failure.notAuthentic) { try kid.receive(frame) }

        // On a new connection, with a recorded hello: the kid's fresh nonce makes new keys.
        var (kid2, _) = try connect()
        #expect(throws: LinkSession.Failure.notAuthentic) { try kid2.receive(frame) }
    }

    @Test func reflectedFramesDontOpen() throws {
        var (_, parent) = try connect()
        let own = try parent.send(grantBundle)
        #expect(throws: LinkSession.Failure.notAuthentic) { try parent.receive(own) }

        var echo = LinkSession(key: key, side: .dialer, hello: parentHello)
        #expect(throws: LinkSession.Failure.notAuthentic) { try echo.receive(echo.start()) }
    }

    @Test func noBundlesBeforeHello() throws {
        var session = LinkSession(key: key, side: .dialer, hello: parentHello)
        #expect(throws: LinkSession.Failure.notReady) { try session.send(grantBundle) }
    }

    @Test func oversizedFrameIsRefused() throws {
        var session = LinkSession(key: key, side: .listener, hello: kidHello)
        let header = withUnsafeBytes(of: UInt32(LinkSession.maxFrameLength + 1).bigEndian) { Data($0) }
        #expect(throws: LinkSession.Failure.frameTooLarge(LinkSession.maxFrameLength + 1)) { try session.receive(header) }
    }

    @Test func tagsAndNamesAreStablePerKey() {
        let copy = LinkKey(secret: key.secret, createdAt: key.createdAt)
        #expect(copy.familyTag == key.familyTag)
        #expect(copy.serviceName(kid: testKid.id) == key.serviceName(kid: testKid.id))
        #expect(LinkKey.generate().familyTag != key.familyTag)
        #expect(!key.serviceName(kid: testKid.id).contains(testKid.displayName))
        #expect(copy.bluetoothServiceID == key.bluetoothServiceID)
        #expect(key.bluetoothServiceID != key.bluetoothChannelID)
        #expect(LinkKey.generate().bluetoothServiceID != key.bluetoothServiceID)
        #expect(key.bluetoothServiceID.uuidString.dropFirst(14).first == "4")
    }

    @Test func sentFilterSendsOnlyChanges() {
        var filter = LinkSentFilter()
        var bundle = grantBundle
        bundle.ruleSets = [RuleSet(kidID: testKid.id, rules: [], updatedAt: at(9, 0))]
        #expect(filter.unsent(bundle) == bundle)
        #expect(filter.unsent(bundle).isEmpty)

        // A new date alone isn't a change; new rules are.
        bundle.ruleSets = [RuleSet(kidID: testKid.id, rules: [], updatedAt: at(10, 0))]
        #expect(filter.unsent(bundle).isEmpty)
        let rule = Rule(kidID: testKid.id, condition: .newApp)
        bundle.ruleSets = [RuleSet(kidID: testKid.id, rules: [rule], updatedAt: at(10, 0))]
        #expect(filter.unsent(bundle).ruleSets.count == 1)

        filter.reset()
        #expect(filter.unsent(bundle).count == 2)
    }

    @Test func onlyKeepsOneKid() {
        var bundle = grantBundle
        let other = TimeRequest(kidID: UUID(), itemID: nil, reason: .blocked, minutes: 5, at: at(9, 0))
        bundle.requests = [other]
        bundle.kids = [testKid, Kid(displayName: "Sam")]
        let only = bundle.only(kid: testKid.id)
        #expect(only.kids == [testKid])
        #expect(only.requests.isEmpty)
        #expect(only.grants == grantBundle.grants)
    }
}
