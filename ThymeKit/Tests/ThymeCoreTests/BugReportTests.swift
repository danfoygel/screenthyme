import Foundation
import Testing
@testable import ThymeCore

struct BugReportTests {
    let tracker = IssueTracker(repository: " family/screenthyme-bugs ", token: "token\n", updatedAt: at(8, 0))
    let report: BugReport = {
        var report = BugReport(id: UUID(uuidString: "12345678-0000-0000-0000-000000000000")!, kidID: testKid.id,
                               reporter: "Emma", at: at(9, 30),
                               text: "The timer | says zero\nbut I still have time", screenshots: ["1.jpg", "2.jpg"],
                               details: [.init("App version", "1.0 (7)")], log: ["09:29:58 rules updated: 3"])
        report.uploaded = ["1.jpg": URL(string: "https://github.com/family/screenthyme-bugs/blob/main/a/1.jpg")!]
        return report
    }()

    /// Answers requests from a script, and records them.
    final class FakeGitHub: @unchecked Sendable {
        var answers: [(Int, String)]
        var requests: [URLRequest] = []
        init(_ answers: [(Int, String)]) { self.answers = answers }

        var transport: GitHubIssues.Transport {
            { request in
                self.requests.append(request)
                let (status, body) = self.answers.removeFirst()
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                                         headerFields: nil)!)
            }
        }
    }

    @Test func trackerTrimsAndChecksRepository() {
        #expect(tracker.repository == "family/screenthyme-bugs" && tracker.token == "token")
        #expect(tracker.isUsable)
        #expect(!IssueTracker.isValidRepository("screenthyme-bugs"))
        #expect(!IssueTracker.isValidRepository("family/bugs/extra"))
        #expect(!IssueTracker.isValidRepository("family/bu gs"))
        #expect(!IssueTracker(repository: "family/bugs", token: " ", updatedAt: at(8, 0)).isUsable)
    }

    @Test func summaryIsTheFirstLineShortened() {
        #expect(report.summary == "The timer | says zero")
        var long = report
        long.text = String(repeating: "word ", count: 30)
        #expect(long.summary.count == 72 && long.summary.hasSuffix("…"))
        long.text = "  \n"
        #expect(long.summary == "Screenshots")
        long.screenshots = []
        #expect(long.summary == "Problem report")
    }

    @Test func bodyShowsUploadedScreenshotsDetailsAndLog() {
        let body = GitHubIssues.body(of: report)
        #expect(GitHubIssues.title(of: report) == "Emma: The timer | says zero")
        #expect(body.hasPrefix("The timer | says zero\nbut I still have time\n\n"))
        #expect(body.contains("![Screenshot 1](https://github.com/family/screenthyme-bugs/blob/main/a/1.jpg?raw=true)"))
        #expect(!body.contains("Screenshot 2"))
        #expect(body.contains("| From | Emma |\n| App version | 1.0 (7) |"))
        #expect(body.contains("````\n09:29:58 rules updated: 3\n````"))
        #expect(body.contains("12345678-0000-0000-0000-000000000000"))
    }

    @Test func reportsQueuedAsKidNameStillDecode() throws {
        let data = try JSONEncoder().encode(report)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#""kidName":"Emma""#))
        #expect(try JSONDecoder().decode(BugReport.self, from: data) == report)
        var parent = report
        parent.kidID = nil
        #expect(try JSONDecoder().decode(BugReport.self, from: JSONEncoder().encode(parent)).kidID == nil)
    }

    @Test func uploadCommitsTheScreenshot() async throws {
        let github = FakeGitHub([(201, #"{"content": {"html_url": "https://github.com/f/b/blob/main/x.jpg"}}"#)])
        let url = try await GitHubIssues(tracker: tracker, transport: github.transport)
            .upload(Data([1, 2, 3]), screenshot: "2.jpg", of: report)
        #expect(url.absoluteString == "https://github.com/f/b/blob/main/x.jpg")
        let request = try #require(github.requests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.absoluteString
            == "https://api.github.com/repos/family/screenthyme-bugs/contents/reports/2026-11-14-12345678/2.jpg")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        let sent = try JSONDecoder().decode([String: String].self, from: try #require(request.httpBody))
        #expect(sent["content"] == "AQID")
    }

    @Test func uploadFindsAScreenshotAlreadyThere() async throws {
        let github = FakeGitHub([(422, #"{"message": "sha wasn't supplied"}"#),
                                 (200, #"{"html_url": "https://github.com/f/b/blob/main/x.jpg"}"#)])
        let url = try await GitHubIssues(tracker: tracker, transport: github.transport)
            .upload(Data(), screenshot: "1.jpg", of: report)
        #expect(url.absoluteString == "https://github.com/f/b/blob/main/x.jpg")
        #expect(github.requests.map(\.httpMethod) == ["PUT", "GET"])
    }

    @Test func gitHubErrorsCarryItsMessage() async {
        let github = FakeGitHub([(401, #"{"message": "Bad credentials"}"#)])
        await #expect(throws: GitHubIssues.Failure.http(status: 401, message: "Bad credentials")) {
            try await GitHubIssues(tracker: tracker, transport: github.transport).openIssue(for: report)
        }
    }

    @Test func openIssuePostsTitleAndBody() async throws {
        let github = FakeGitHub([(201, #"{"number": 4, "html_url": "https://github.com/f/b/issues/4"}"#)])
        let url = try await GitHubIssues(tracker: tracker, transport: github.transport).openIssue(for: report)
        #expect(url.absoluteString == "https://github.com/f/b/issues/4")
        let request = try #require(github.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/repos/family/screenthyme-bugs/issues")
        let sent = try JSONDecoder().decode([String: String].self, from: try #require(request.httpBody))
        #expect(sent["title"] == GitHubIssues.title(of: report) && sent["body"] == GitHubIssues.body(of: report))
    }

    @Test func resolutionAsksTheIssuesOwnRepository() async throws {
        let github = FakeGitHub([
            (200, #"{"state": "open", "state_reason": null}"#),
            (200, #"{"state": "closed", "state_reason": "completed"}"#),
            (200, #"{"state": "closed", "state_reason": "not_planned"}"#),
            (404, #"{"message": "Not Found"}"#),
        ])
        let issues = GitHubIssues(tracker: tracker, transport: github.transport)
        let issue = URL(string: "https://github.com/other/bugs/issues/12")!
        #expect(try await issues.resolution(of: issue) == nil)
        #expect(try await issues.resolution(of: issue) == .fixed)
        #expect(try await issues.resolution(of: issue) == .closed)
        await #expect(throws: GitHubIssues.Failure.http(status: 404, message: "Not Found")) {
            try await issues.resolution(of: issue)
        }
        #expect(github.requests.allSatisfy {
            $0.httpMethod == "GET" && $0.url?.absoluteString == "https://api.github.com/repos/other/bugs/issues/12"
        })
        #expect(GitHubIssues.apiURL(of: URL(string: "https://github.com/other/bugs/pull/12")!) == nil)
        #expect(GitHubIssues.apiURL(of: URL(string: "https://example.com/other/bugs/issues/12")!) == nil)
    }

    @Test func bodyTellsTheWorkflowWhichPhoneToPush() throws {
        #expect(!GitHubIssues.body(of: report).contains("screenthyme-fixed"))
        var pushed = report
        pushed.phoneID = UUID(uuidString: "ABCDEF00-0000-0000-0000-000000000000")
        pushed.text = "It says --> nothing"
        let body = GitHubIssues.body(of: pushed)
        let marker = try #require(body.split(separator: "\n\n").last)
        #expect(marker.hasPrefix("<!-- screenthyme-fixed {") && marker.hasSuffix("} -->"))
        #expect(marker.components(separatedBy: "-->").count == 2)
        let json = marker.dropFirst("<!-- screenthyme-fixed ".count).dropLast(" -->".count)
        let fields = try JSONDecoder().decode([String: String].self, from: Data(json.utf8))
        #expect(fields == ["phone": "abcdef00-0000-0000-0000-000000000000", "report": pushed.id.uuidString,
                           "title": "A problem you reported is fixed",
                           "body": "You reported: “It says --> nothing” Thanks for telling us!"])
    }

    @Test func savePhoneReplacesTheOldToken() async throws {
        let phone = PushPhone(token: "ab12", topic: "com.example.app", environment: "development", updatedAt: at(9, 0))
        let id = UUID(uuidString: "ABCDEF00-0000-0000-0000-000000000000")!
        let github = FakeGitHub([(200, #"{"sha": "old", "html_url": "https://github.com/f/b/blob/main/p.json"}"#),
                                 (200, #"{"content": {"html_url": "https://github.com/f/b/blob/main/p.json"}}"#)])
        try await GitHubIssues(tracker: tracker, transport: github.transport).save(phone, id: id)
        #expect(github.requests.map(\.httpMethod) == ["GET", "PUT"])
        #expect(github.requests.allSatisfy {
            $0.url?.path == "/repos/family/screenthyme-bugs/contents/phones/abcdef00-0000-0000-0000-000000000000.json"
        })
        let sent = try JSONDecoder().decode([String: String].self, from: try #require(github.requests[1].httpBody))
        #expect(sent["sha"] == "old")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let base64 = try #require(sent["content"])
        let content = try #require(Data(base64Encoded: base64))
        #expect(try decoder.decode(PushPhone.self, from: content) == phone)

        let first = FakeGitHub([(404, #"{"message": "Not Found"}"#),
                                (201, #"{"content": {"html_url": "https://github.com/f/b/blob/main/p.json"}}"#)])
        try await GitHubIssues(tracker: tracker, transport: first.transport).save(phone, id: id)
        let created = try JSONDecoder().decode([String: String].self, from: try #require(first.requests[1].httpBody))
        #expect(created["sha"] == nil)
    }

    @Test func fixedNotificationQuotesTheReport() throws {
        #expect(report.fixedNotification.body == "You reported: “The timer | says zero” Thanks for telling us!")
        var pictures = report
        pictures.text = " "
        #expect(pictures.fixedNotification.body.hasPrefix("The problem you reported on "))
        let decoded = try JSONDecoder().decode(BugReport.self, from: JSONEncoder().encode(report))
        #expect(decoded.resolution == nil)
        pictures.resolution = .fixed
        pictures.phoneID = UUID()
        #expect(try JSONDecoder().decode(BugReport.self, from: JSONEncoder().encode(pictures)) == pictures)
    }
}
