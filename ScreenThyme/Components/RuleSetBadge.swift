import SwiftUI
import ThymeCore

/// The ruleset in effect today (PLAN.md §15.15), and whether a parent chose it: on a kid's card, and on the kid's own
/// phone.
struct RuleSetBadge: View {
    let policy: Policy
    var now = Date()

    var body: some View {
        if let set = policy.ruleSet(on: now) {
            let choice = policy.choice(on: now)
            Label {
                Text("\(set.name) rules").bold()
                    + Text(choice.map { " · chosen, \($0.span().lowercasedFirst)" } ?? "")
            } icon: {
                Image(systemName: choice == nil ? "calendar" : "hand.point.up.left.fill")
            }
            .foregroundStyle(choice == nil ? Color.accentColor : .orange)
        }
    }
}

extension String {
    /// "Today only" → "today only".
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
