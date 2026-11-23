import Foundation
import Testing
@testable import ThymeCore

/// How much more time a kid asks for and a parent gives, and how the Alerts list says what was asked and given.
struct MoreTimeTests {
    let request = TimeRequest(kidID: testKid.id, itemID: UUID(), reason: .limit(UUID()), minutes: 60, at: at(16, 41))

    @Test func stepsMoveToTheNextAmountAndStopAtTheEnds() {
        #expect(MoreTime.step(15, up: true) == 20)
        #expect(MoreTime.step(15, up: false) == 10)
        #expect(MoreTime.step(25, up: true) == 30)
        #expect(MoreTime.step(25, up: false) == 20)
        #expect(MoreTime.step(240, up: true) == 240)
        #expect(MoreTime.step(5, up: false) == 5)
    }

    @Test func amountsReadAsMinutesOrHours() {
        #expect(MoreTime.describe(minutes: 1) == "1 more minute")
        #expect(MoreTime.describe(minutes: 20) == "20 more minutes")
        #expect(MoreTime.describe(minutes: 60) == "1 more hour")
        #expect(MoreTime.describe(minutes: 90) == "1 h 30 min more")
        #expect(MoreTime.describe(minutes: 180) == "3 more hours")
        #expect(MoreTime.describe(minutes: nil) == "the rest of today")
    }

    @Test func outcomeSaysWhatWasGivenOnlyWhenItDiffers() {
        func answer(_ approved: Bool, _ minutes: Int?) -> TimeGrant {
            TimeGrant(request: request, approved: approved, minutes: minutes, at: at(16, 42), by: "Mom")
        }
        #expect(MoreTime.outcome(of: request, answer: nil) == "Asked for 1 more hour · not answered yet")
        #expect(MoreTime.outcome(of: request, answer: answer(true, 60)) == "Asked for 1 more hour · Mom said yes")
        #expect(MoreTime.outcome(of: request, answer: answer(true, 30))
            == "Asked for 1 more hour · Mom gave 30 more minutes")
        #expect(MoreTime.outcome(of: request, answer: answer(true, nil))
            == "Asked for 1 more hour · Mom gave the rest of today")
        #expect(MoreTime.outcome(of: request, answer: answer(false, nil)) == "Asked for 1 more hour · Mom said no")
    }

    @Test func alertsFindTheRequestTheyWereSentWith() {
        let other = TimeRequest(kidID: testKid.id, itemID: UUID(), reason: .blocked, minutes: 15, at: at(16, 41))
        let alert = AlertRecord(kidID: testKid.id, ruleID: nil, itemID: request.itemID,
                                at: request.at.addingTimeInterval(0.0004), title: "", body: "")
        #expect(TimeRequest.sent(with: alert, from: [other, request]) == request)
        var ruleAlert = alert
        ruleAlert.ruleID = UUID()
        #expect(TimeRequest.sent(with: ruleAlert, from: [request]) == nil)
        var later = alert
        later.at = request.at.addingTimeInterval(60)
        #expect(TimeRequest.sent(with: later, from: [request]) == nil)
    }
}
