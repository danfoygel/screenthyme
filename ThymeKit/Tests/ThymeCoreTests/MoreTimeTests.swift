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
        #expect(MoreTime.outcome(of: request, answer: answer(true, 30).ending(at: at(16, 50), by: "Dad"))
            == "Asked for 1 more hour · Mom gave 30 more minutes · Dad ended it early")
    }

    @Test func selfApprovalGivesWhatWasAskedAndSaysSo() {
        let grant = TimeGrant.selfApproved(request, by: "Sam", because: "Need the map to get home", at: at(16, 50))
        #expect(grant.approved && grant.minutes == 60 && grant.requestID == request.id && grant.itemID == request.itemID)
        #expect(grant.isSelfApproved && grant.by == "Sam")
        #expect(MoreTime.outcome(of: request, answer: grant) == "Asked for 1 more hour · self-approved, no parent answered")
        #expect(MoreTime.outcome(of: request, answer: grant.ending(at: at(16, 55), by: "Mom"))
            == "Asked for 1 more hour · self-approved, no parent answered · Mom ended it early")
        let parents = TimeGrant(request: request, approved: true, minutes: 60, at: at(16, 50), by: "Mom")
        #expect(!parents.isSelfApproved)
    }

    @Test func onlyDowntimeAndLimitRequestsCanBeSelfApproved() {
        func request(_ reason: BlockReason) -> TimeRequest {
            TimeRequest(kidID: testKid.id, itemID: UUID(), reason: reason, minutes: 15, at: at(16, 41))
        }
        #expect(request(.downtime(UUID())).canSelfApprove)
        #expect(request(.limit(UUID())).canSelfApprove)
        #expect(!request(.blocked).canSelfApprove)
        #expect(!request(.alwaysAllow).canSelfApprove)
    }

    @Test func grantsSavedBeforeSelfApprovalStillDecode() throws {
        let old = TimeGrant(request: request, approved: true, minutes: 30, at: at(16, 42), by: "Mom")
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder.thyme.encode(old)) as? [String: Any])
        json["selfApproval"] = nil
        let decoded = try JSONDecoder.thyme.decode(TimeGrant.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == old && !decoded.isSelfApproved)
    }

    @Test func selfApprovalAlertsFindTheirGrant() {
        let grant = TimeGrant.selfApproved(request, by: "Sam", because: "Need the map to get home", at: at(16, 50))
        let parents = TimeGrant(request: request, approved: true, minutes: 60, at: at(16, 50), by: "Mom")
        let alert = AlertRecord(kidID: testKid.id, ruleID: nil, itemID: request.itemID, at: grant.at, title: "", body: "")
        #expect(TimeGrant.selfApproved(with: alert, from: [parents, grant]) == grant)
        #expect(TimeGrant.selfApproved(with: alert, from: [parents]) == nil)
        var asked = alert
        asked.at = request.at
        #expect(TimeGrant.selfApproved(with: asked, from: [grant]) == nil)
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

    @Test func listTitleDropsOnlyALeadingWarning() {
        func title(_ text: String) -> String {
            AlertRecord(kidID: testKid.id, ruleID: nil, itemID: nil, at: at(16, 41), title: text, body: "").listTitle
        }
        #expect(title("\u{26A0}\u{FE0F} Kid self-approved more time") == "Kid self-approved more time")
        #expect(title("\u{26A0} Kid self-approved more time") == "Kid self-approved more time")
        #expect(title("Kid asked for more time") == "Kid asked for more time")
        #expect(title("Kid \u{26A0}\u{FE0F} self-approved") == "Kid \u{26A0}\u{FE0F} self-approved")
    }

    @Test func alertsBodyNamesTheItemOrNot() {
        func alert(_ body: String) -> AlertRecord {
            AlertRecord(kidID: testKid.id, ruleID: nil, itemID: UUID(), at: at(16, 41), title: "", body: body)
        }
        let named = alert("Asked for 1 more hour for sound555 during Downtime.")
        #expect(named.namesItem("sound555"))
        #expect(named.namesItem("Sound555"))
        #expect(!named.namesItem("Maps"))
        #expect(!named.namesItem(""))
        #expect(!alert("Asked for 1 more hour for this app during Downtime.").namesItem("sound555"))
    }
}
