import Foundation

/// A report of a problem with ScreenThyme, from a kid's phone or a parent's (PLAN.md §18). The phone files it as an issue
/// in the family's private GitHub repository (`IssueTracker`), and keeps it queued until then.
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
    /// The kid, when sent from a kid's phone.
    public var kidID: UUID?
    /// Who sent it: the kid's name, or the parent's.
    public var reporter: String
    public var at: Date
    /// The reporter's own words.
    public var text: String
    /// File names in the phone's folder for this report, in the order chosen.
    public var screenshots: [String]
    /// App version, iOS, Screen Time access and the like, as the phone saw them when sent.
    public var details: [Detail]
    /// Recent journal notes, oldest first.
    public var log: [String]

    // Filing progress, so a retry neither uploads a screenshot twice nor opens a second issue.
    /// Screenshot file name → its page in the repository.
    public var uploaded: [String: URL] = [:]
    public var issueURL: URL?
    public var lastError: String?

    // Reports queued before parents could send them named the reporter `kidName`.
    enum CodingKeys: String, CodingKey {
        case id, kidID, reporter = "kidName", at, text, screenshots, details, log, uploaded, issueURL, lastError
    }

    public init(id: UUID = UUID(), kidID: UUID?, reporter: String, at: Date, text: String, screenshots: [String] = [],
                details: [Detail] = [], log: [String] = []) {
        self.id = id
        self.kidID = kidID
        self.reporter = reporter
        self.at = at
        self.text = text
        self.screenshots = screenshots
        self.details = details
        self.log = log
    }

    public var isFiled: Bool { issueURL != nil }

    /// The first line of the reporter's words, shortened.
    public var summary: String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return screenshots.isEmpty ? "Problem report" : "Screenshots" }
        return line.count > 72 ? line.prefix(71).trimmingCharacters(in: .whitespaces) + "…" : line
    }
}

/// Where family phones file bug reports: a GitHub repository and a token that can write its issues and contents.
/// One per family, saved by a parent as `IssueTracker.<fixed id>` and fetched by name on each phone that files one.
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
