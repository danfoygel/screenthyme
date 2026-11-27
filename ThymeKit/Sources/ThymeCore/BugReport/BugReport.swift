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

    /// What the reporter is sending: a problem, an idea or a question. The issue gets its label.
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        case bug, feature, question

        /// The bug repository's label: GitHub's own defaults, so "feature" is "enhancement".
        public var label: String {
            switch self {
            case .bug: "bug"
            case .feature: "enhancement"
            case .question: "question"
            }
        }

        /// What the list says once its issue is closed as completed.
        public var doneStatus: String {
            switch self {
            case .bug: "Fixed"
            case .feature: "Done"
            case .question: "Answered"
            }
        }
    }

    public var id: UUID
    /// Nil in reports queued before the reporter chose one; they're filed as problems without a label.
    public var kind: Kind?
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
    /// How its issue was closed, as last seen on GitHub; nil while it's open.
    public var resolution: Resolution?
    /// The phone that sent it (`PushPhone`), which GitHub tells when it's fixed.
    public var phoneID: UUID?

    /// How a filed report's issue was closed: as done (fixed), or for any other reason (not planned, a duplicate).
    public enum Resolution: String, Codable, Sendable, Hashable {
        case fixed, closed
    }

    // Reports queued before parents could send them named the reporter `kidName`.
    enum CodingKeys: String, CodingKey {
        case id, kind, kidID, reporter = "kidName", at, text, screenshots, details, log, uploaded, issueURL, lastError,
             resolution, phoneID
    }

    public init(id: UUID = UUID(), kind: Kind? = nil, kidID: UUID?, reporter: String, at: Date, text: String, screenshots: [String] = [],
                details: [Detail] = [], log: [String] = [], phoneID: UUID? = nil) {
        self.id = id
        self.kind = kind
        self.phoneID = phoneID
        self.kidID = kidID
        self.reporter = reporter
        self.at = at
        self.text = text
        self.screenshots = screenshots
        self.details = details
        self.log = log
    }

    public var isFiled: Bool { issueURL != nil }

    /// Filed, and not fixed yet as far as this phone knows. A closed issue can still be reopened and fixed.
    public var awaitsFix: Bool { isFiled && resolution != .fixed }

    /// The push that tells the reporter its issue was closed, fixed (done, answered) or not, sent by the repository's
    /// workflow (`Tools/BugPush`).
    public func closedNotification(fixed: Bool) -> (title: String, body: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let day = at.formatted(.dateTime.month(.abbreviated).day())
        switch kind ?? .bug {
        case .bug:
            if fixed {
                let what = text.isEmpty ? "The problem you reported on \(day) is fixed." : "You reported: “\(summary)”"
                return ("A problem you reported is fixed", what + " Thanks for telling us!")
            }
            let what = text.isEmpty ? "The problem you reported on \(day)" : "You reported: “\(summary)”. It"
            return ("A problem you reported was closed", what + " was closed without a fix.")
        case .feature:
            if fixed {
                let what = text.isEmpty ? "The idea you sent on \(day) is done." : "You suggested: “\(summary)”"
                return ("An idea you sent is done", what + " Thanks for the idea!")
            }
            let what = text.isEmpty ? "The idea you sent on \(day)" : "You suggested: “\(summary)”. It"
            return ("An idea you sent was closed", what + " was closed without being done.")
        case .question:
            if fixed {
                let what = text.isEmpty ? "The question you asked on \(day) was answered." : "You asked: “\(summary)”"
                return ("Your question was answered", what)
            }
            let what = text.isEmpty ? "The question you asked on \(day)" : "You asked: “\(summary)”. It"
            return ("A question you asked was closed", what + " was closed without an answer.")
        }
    }

    /// The first line of the reporter's words, shortened.
    public var summary: String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else {
            if !screenshots.isEmpty { return "Screenshots" }
            switch kind ?? .bug {
            case .bug: return "Problem report"
            case .feature: return "Idea"
            case .question: return "Question"
            }
        }
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

/// A phone that can be told its reports are fixed: its APNs device token, saved as `phones/<id>.json` in the family's
/// bug repository. When an issue is closed as done, the repository's workflow (`Tools/BugPush`) pushes the
/// notification named in the issue to the phone named there.
public struct PushPhone: Codable, Sendable, Hashable {
    /// Hex.
    public var token: String
    /// The app's bundle ID.
    public var topic: String
    /// "development" or "production", as the app's `aps-environment`.
    public var environment: String
    public var updatedAt: Date

    public init(token: String, topic: String, environment: String, updatedAt: Date) {
        self.token = token
        self.topic = topic
        self.environment = environment
        self.updatedAt = updatedAt
    }

    public static func path(of id: UUID) -> String {
        "phones/\(id.uuidString.lowercased()).json"
    }
}
