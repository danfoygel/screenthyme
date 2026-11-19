import Foundation

/// A kid's report of a problem with ScreenThyme (PLAN.md §18). The kid's own phone files it as an issue in the family's
/// private GitHub repository (`IssueTracker`), and keeps it queued until then.
public struct BugReport: Codable, Sendable, Hashable, Identifiable {
    public struct Detail: Codable, Sendable, Hashable {
        public var label: String
        public var value: String

        public init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    public var id: UUID
    public var kidID: UUID
    public var kidName: String
    public var at: Date
    /// The kid's own words.
    public var text: String
    /// File names in the phone's folder for this report, in the order chosen.
    public var screenshots: [String]
    /// App version, iOS, Screen Time access and the like, as the phone saw them when the kid sent it.
    public var details: [Detail]
    /// Recent journal notes, oldest first.
    public var log: [String]

    // Filing progress, so a retry neither uploads a screenshot twice nor opens a second issue.
    /// Screenshot file name → its page in the repository.
    public var uploaded: [String: URL] = [:]
    public var issueURL: URL?
    public var lastError: String?

    public init(id: UUID = UUID(), kidID: UUID, kidName: String, at: Date, text: String, screenshots: [String] = [],
                details: [Detail] = [], log: [String] = []) {
        self.id = id
        self.kidID = kidID
        self.kidName = kidName
        self.at = at
        self.text = text
        self.screenshots = screenshots
        self.details = details
        self.log = log
    }

    public var isFiled: Bool { issueURL != nil }

    /// The first line of the kid's words, shortened.
    public var summary: String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return screenshots.isEmpty ? "Problem report" : "Screenshots" }
        return line.count > 72 ? line.prefix(71).trimmingCharacters(in: .whitespaces) + "…" : line
    }
}

/// Where kids' phones file bug reports: a GitHub repository and a token that can write its issues and contents.
/// One per family, saved by a parent as `IssueTracker.<fixed id>` and fetched by name on the kid's phone.
public struct IssueTracker: Codable, Sendable, Hashable, Identifiable {
    public static let fixedID = Replay.stableUUID("issue-tracker")

    public var id: UUID
    /// "owner/name".
    public var repository: String
    public var token: String
    public var updatedAt: Date

    public init(repository: String, token: String, updatedAt: Date) {
        self.id = Self.fixedID
        self.repository = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.updatedAt = updatedAt
    }

    public static func isValidRepository(_ repository: String) -> Bool {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return parts.count == 2 && parts.allSatisfy {
            !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains)
        }
    }

    public var isUsable: Bool { Self.isValidRepository(repository) && !token.isEmpty }
}
