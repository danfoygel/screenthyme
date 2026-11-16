import Foundation
import Testing
@testable import ThymeCore

struct TokenMatchingTests {
    let a = UUID(), b = UUID(), c = UUID()

    @Test func theAppWithAboutAMinuteSinceRegistrationMatches() {
        // a: 70 s since registration; b: long used, little since; c: 10 min since (its own event fired earlier).
        let result = TokenMatching.match(baseline: [a: 100, b: 3000, c: 0], usage: [a: 170, b: 3010, c: 600],
                                         candidates: [a, b, c])
        #expect(result == .matched(a))
    }

    @Test func twoAppsNearAMinuteAreAmbiguous() {
        let result = TokenMatching.match(baseline: [:], usage: [a: 65, b: 120], candidates: [a, b])
        #expect(result == .ambiguous([a, b]))
    }

    @Test func alreadyMatchedAppsAreNotCandidates() {
        #expect(TokenMatching.match(baseline: [:], usage: [a: 65, b: 120], candidates: [b]) == .matched(b))
        #expect(TokenMatching.match(baseline: [:], usage: [a: 30], candidates: [a]) == .none)
    }

    @Test func builtInAppsHaveNames() {
        let safari = TrackedItem(kidID: UUID(), kind: .app, identifier: "com.apple.mobilesafari", firstSeen: Date())
        #expect(safari.displayName == "Safari")
    }
}
