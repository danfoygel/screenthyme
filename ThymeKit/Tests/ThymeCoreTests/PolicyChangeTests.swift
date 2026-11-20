import Foundation
import Testing
@testable import ThymeCore

struct PolicyChangeTests {
    let kid = testKid.id
    let roblox = UUID(), youtube = UUID(), games = UUID()
    var names: [UUID: String] { [roblox: "Roblox", youtube: "YouTube", games: "Games"] }

    func describe(_ edit: PolicyEdit) -> (title: String, details: [String]) {
        edit.describe(calendar: utc) { names[$0] ?? "?" }
    }

    @Test func groupsAndScopedDowntimeAreDescribed() {
        let group = ItemGroup(name: "Fun", items: [roblox])
        let window = DowntimeWindow(name: "Homework", startMinute: 16 * 60, endMinute: 18 * 60)
        let old = Policy(kidID: kid, downtime: [window], groups: [group])
        var new = old
        new.groups[0].items.insert(youtube)
        new.downtime[0].items = [games]
        new.groups.append(ItemGroup(name: "School", items: []))
        let edits = PolicyEdit.between(old, new)
        #expect(edits.map { describe($0).title } == ["Changed Downtime \u{201C}Homework\u{201D}",
                                                     "Changed group \u{201C}Fun\u{201D}", "Added group \u{201C}School\u{201D}"])
        #expect(describe(edits[0]).details == ["Now only Games"])
        #expect(describe(edits[1]).details == ["Added YouTube"])
    }

    @Test func policyInForceAtATime() {
        let first = Policy(kidID: kid, blocked: [roblox])
        let current = Policy(kidID: kid, blocked: [games])
        let changes = [PolicyChange(kidID: kid, at: at(12, 0), by: "Dad", before: first, after: Policy(kidID: kid, blocked: [youtube])),
                       PolicyChange(kidID: kid, at: at(9, 0), by: "Mom", before: nil, after: first)]
        #expect(PolicyChange.policy(at: at(8, 0), changes: changes, current: current) == nil)
        #expect(PolicyChange.policy(at: at(10, 0), changes: changes, current: current) == first)
        #expect(PolicyChange.policy(at: at(11, 59), changes: changes, current: current) == first)
        #expect(PolicyChange.policy(at: at(12, 0), changes: changes, current: current) == current)
        #expect(PolicyChange.policy(at: at(8, 0), changes: [], current: current) == current)
    }

    @Test func unchangedPolicyHasNoEdits() {
        let policy = Policy(kidID: kid, downtime: [DowntimeWindow(name: "Bedtime", startMinute: 1290, endMinute: 420)],
                            blocked: [roblox])
        var later = policy
        later.updatedAt = later.updatedAt.addingTimeInterval(60)
        #expect(PolicyEdit.between(policy, later).isEmpty)
    }

    @Test func firstPolicyIsComparedWithAnEmptyOne() {
        let window = DowntimeWindow(name: "Bedtime", startMinute: 21 * 60 + 30, endMinute: 7 * 60)
        let change = PolicyChange(kidID: kid, at: dayStart, by: "Mom", before: nil,
                                  after: Policy(kidID: kid, downtime: [window], blocked: [roblox]))
        #expect(change.edits == [.downtimeAdded(window), .blocked(added: [roblox], removed: [])])
        #expect(describe(change.edits[0]).title == "Added Downtime \u{201C}Bedtime\u{201D}")
        #expect(describe(change.edits[0]).details == ["21:30–7:00, every day"])
        #expect(describe(change.edits[1]).details == ["Added Roblox"])
    }

    @Test func windowsAndLimitsMatchByID() {
        let window = DowntimeWindow(name: "School", startMinute: 8 * 60, endMinute: 15 * 60, weekdays: [2, 3])
        let limit = AppLimit(name: "Games", items: [games], minutes: 60)
        let old = Policy(kidID: kid, downtime: [window], limits: [limit])
        var new = old
        new.downtime[0].endMinute = 14 * 60
        new.downtime[0].name = "Classes"
        new.limits[0].minutes = 45
        new.limits[0].weekdayMinutes = [7: 120]
        new.limits[0].items = [games, roblox]
        let edits = PolicyEdit.between(old, new)
        #expect(edits.count == 2)
        #expect(describe(edits[0]).title == "Changed Downtime \u{201C}Classes\u{201D}")
        #expect(describe(edits[0]).details == ["Renamed from \u{201C}School\u{201D}",
                                              "8:00–15:00, Mon Tue → 8:00–14:00, Mon Tue"])
        #expect(describe(edits[1]).details == ["1 h 0 min → 45 min a day", "\(utc.weekdaySymbols[6]): same → 2 h 0 min", "Added Roblox"])
    }

    @Test func removalsComeBeforeAdditions() {
        let a = AppLimit(name: "A", items: [games], minutes: 30), b = AppLimit(name: "B", items: [youtube], minutes: 30)
        let edits = PolicyEdit.between(Policy(kidID: kid, limits: [a]), Policy(kidID: kid, limits: [b]))
        #expect(edits == [.limitRemoved(a), .limitAdded(b)])
    }

    @Test func enforcementAndListsAndRestrictions() {
        let old = Policy(kidID: kid, alwaysAllowed: [youtube])
        var new = Policy(kidID: kid, enabled: false, alwaysAllowed: [roblox, games])
        new.restrictions.denySiri = true
        new.restrictions.maximumAppRating = 300
        new.restrictions.webFilter = .allowedOnly(["pbskids.org"])
        let edits = PolicyEdit.between(old, new)
        #expect(edits == [
            .enforcement(on: false),
            .alwaysAllowed(added: [roblox, games], removed: [youtube]),
            .restriction(name: "Apps up to", from: "All", to: "12+"),
            .restriction(name: "Websites", from: "Unrestricted", to: "Allowed websites only"),
            .restriction(name: "Block Siri", from: "Off", to: "On"),
            .websites(list: "allowed websites", added: ["pbskids.org"], removed: []),
        ])
        #expect(describe(edits[1]).details == ["Added Games, Roblox", "Removed YouTube"])
        #expect(describe(edits[2]).title == "Apps up to: 12+")
    }

    @Test func roundTripsThroughJSON() throws {
        let change = PolicyChange(kidID: kid, at: dayStart, by: "Dad", before: Policy(kidID: kid, updatedAt: dayStart),
                                  after: Policy(kidID: kid, updatedAt: at(9, 30), blocked: [roblox]))
        let decoded = try JSONDecoder.thyme.decode(PolicyChange.self, from: JSONEncoder.thyme.encode(change))
        #expect(decoded == change)
    }
}
