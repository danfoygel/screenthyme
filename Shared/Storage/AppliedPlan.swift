import Foundation
import ThymeCore

/// The plan the kid's phone last applied (App Group `enforcement.json`), with what the block page needs to explain it.
struct AppliedPlan: Codable, Sendable {
    var plan: EnforcementPlan
    var at: Date
    /// Limit id → name, for "Time limit: Social".
    var limitNames: [UUID: String]
}
