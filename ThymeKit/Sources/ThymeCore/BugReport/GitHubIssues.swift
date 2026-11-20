import Foundation

/// Files a `BugReport` with GitHub's REST API (PLAN.md §18). GitHub's API can't attach images to an issue, so each
/// screenshot is first committed to the repository under `reports/`, and the issue shows it from there: the
/// repository is private, so only people with access to it see them.
public struct GitHubIssues: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public enum Failure: Error, Equatable, LocalizedError {
        case notSetUp
        case http(status: Int, message: String)
        case unexpectedResponse

        public var errorDescription: String? {
            switch self {
            case .notSetUp: "No GitHub repository and token yet"
            case let .http(status, message): "GitHub: \(message) (\(status))"
            case .unexpectedResponse: "GitHub sent an unexpected answer"
            }
        }
    }

    public let tracker: IssueTracker
    let transport: Transport

    public init(tracker: IssueTracker, transport: @escaping Transport = GitHubIssues.urlSession) {
        self.tracker = tracker
        self.transport = transport
    }

    public static let urlSession: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.unexpectedResponse }
        return (data, http)
    }

    /// Where a report's screenshot goes in the repository.
    public static func path(of screenshot: String, in report: BugReport) -> String {
        let day = report.at.formatted(.iso8601.year().month().day())
        return "reports/\(day)-\(report.id.uuidString.prefix(8).lowercased())/\(screenshot)"
    }

    /// Commits a screenshot and returns its page. A screenshot already there (an earlier attempt that failed after
    /// uploading it) is found instead.
    public func upload(_ data: Data, screenshot: String, of report: BugReport) async throws -> URL {
        let path = Self.path(of: screenshot, in: report)
        var put = request("PUT", "contents/\(path)")
        put.httpBody = try JSONEncoder().encode([
            "message": "Bug report from \(report.reporter): \(screenshot)",
            "content": data.base64EncodedString(),
        ])
        let (body, response) = try await transport(put)
        switch response.statusCode {
        case 200, 201:
            return try JSONDecoder().decode(ContentsResult.self, from: body).content.htmlURL
        case 422:
            let (existing, found) = try await transport(request("GET", "contents/\(path)"))
            guard found.statusCode == 200 else { throw Self.failure(response.statusCode, body) }
            return try JSONDecoder().decode(ContentsItem.self, from: existing).htmlURL
        default:
            throw Self.failure(response.statusCode, body)
        }
    }

    /// Opens the issue, with every screenshot in `report.uploaded`. Returns the issue's page.
    public func openIssue(for report: BugReport) async throws -> URL {
        var post = request("POST", "issues")
        post.httpBody = try JSONEncoder().encode(["title": Self.title(of: report), "body": Self.body(of: report)])
        let (body, response) = try await transport(post)
        guard response.statusCode == 201 else { throw Self.failure(response.statusCode, body) }
        return try JSONDecoder().decode(ContentsItem.self, from: body).htmlURL
    }

    /// How a filed report's issue was closed, looked up in whichever repository it was filed in; nil while it's open.
    public func resolution(of issue: URL) async throws -> BugReport.Resolution? {
        guard let url = Self.apiURL(of: issue) else { throw Failure.unexpectedResponse }
        let (body, response) = try await transport(request("GET", url: url))
        guard response.statusCode == 200 else { throw Self.failure(response.statusCode, body) }
        let item = try JSONDecoder().decode(IssueItem.self, from: body)
        guard item.state == "closed" else { return nil }
        return item.stateReason == "completed" ? .fixed : .closed
    }

    /// Saves this phone's push token where the repository's workflow finds it, over any older one.
    public func save(_ phone: PushPhone, id: UUID) async throws {
        let path = PushPhone.path(of: id)
        let (existing, found) = try await transport(request("GET", "contents/\(path)"))
        let sha: String?
        switch found.statusCode {
        case 200: sha = try JSONDecoder().decode(FileSHA.self, from: existing).sha
        case 404: sha = nil
        default: throw Self.failure(found.statusCode, existing)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var put = request("PUT", "contents/\(path)")
        var fields = ["message": "Push token for phone \(id.uuidString.prefix(8).lowercased())",
                      "content": try encoder.encode(phone).base64EncodedString()]
        fields["sha"] = sha
        put.httpBody = try JSONEncoder().encode(fields)
        let (body, response) = try await transport(put)
        guard [200, 201].contains(response.statusCode) else { throw Self.failure(response.statusCode, body) }
    }

    /// What the repository's workflow reads when the issue is closed as done: which phone to push to, and what to
    /// say. An HTML comment, so the issue doesn't show it.
    static func fixMarker(of report: BugReport) -> String? {
        guard let phone = report.phoneID else { return nil }
        let message = report.fixedNotification
        let fields = ["phone": phone.uuidString.lowercased(), "report": report.id.uuidString,
                      "title": message.title, "body": message.body]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let json = try? encoder.encode(fields) else { return nil }
        // "-->" would end the comment early; "\u003e" is the same JSON.
        return "<!-- \(fixMarkerName) " + String(decoding: json, as: UTF8.self)
            .replacingOccurrences(of: ">", with: "\\u003e") + " -->"
    }

    static let fixMarkerName = "screenthyme-fixed"

    /// `https://github.com/<owner>/<name>/issues/<n>` → the API's address for it.
    static func apiURL(of issue: URL) -> URL? {
        let parts = issue.pathComponents.filter { $0 != "/" }
        guard issue.host == "github.com", parts.count == 4, parts[2] == "issues", Int(parts[3]) != nil else { return nil }
        return URL(string: "https://api.github.com/repos/\(parts[0])/\(parts[1])/issues/\(parts[3])")
    }

    public static func title(of report: BugReport) -> String {
        "\(report.reporter): \(report.summary)"
    }

    public static func body(of report: BugReport) -> String {
        var parts: [String] = []
        let text = report.text.trimmingCharacters(in: .whitespacesAndNewlines)
        parts.append(text.isEmpty ? "_No description._" : text)
        let images = report.screenshots.enumerated().compactMap { index, name in
            report.uploaded[name].map { "![Screenshot \(index + 1)](\(rawURL($0)))" }
        }
        if !images.isEmpty { parts.append(images.joined(separator: "\n")) }
        let rows = [BugReport.Detail("From", report.reporter)] + report.details
        parts.append((["| | |", "|---|---|"] + rows.map { "| \(cell($0.label)) | \(cell($0.value)) |" })
            .joined(separator: "\n"))
        if !report.log.isEmpty {
            let log = report.log.map { $0.replacingOccurrences(of: "````", with: "'''") }.joined(separator: "\n")
            parts.append("<details><summary>Recent log</summary>\n\n````\n\(log)\n````\n</details>")
        }
        parts.append("<sub>Filed by ScreenThyme on \(report.reporter)'s phone · report \(report.id.uuidString)</sub>")
        if let marker = fixMarker(of: report) { parts.append(marker) }
        return parts.joined(separator: "\n\n")
    }

    /// A file page's image, which GitHub serves to viewers who can see the (private) repository.
    static func rawURL(_ page: URL) -> String {
        page.absoluteString + "?raw=true"
    }

    private static func cell(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|").split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    private func request(_ method: String, _ endpoint: String) -> URLRequest {
        request(method, url: URL(string: "https://api.github.com/repos/\(tracker.repository)/\(endpoint)")!)
    }

    private func request(_ method: String, url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(tracker.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if method != "GET" { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    private static func failure(_ status: Int, _ body: Data) -> Failure {
        let message = (try? JSONDecoder().decode(Message.self, from: body))?.message
        return .http(status: status, message: message ?? HTTPURLResponse.localizedString(forStatusCode: status))
    }

    private struct ContentsItem: Decodable {
        let htmlURL: URL
        enum CodingKeys: String, CodingKey { case htmlURL = "html_url" }
    }

    private struct IssueItem: Decodable {
        let state: String
        let stateReason: String?
        enum CodingKeys: String, CodingKey { case state, stateReason = "state_reason" }
    }

    private struct FileSHA: Decodable {
        let sha: String
    }

    private struct ContentsResult: Decodable {
        let content: ContentsItem
    }

    private struct Message: Decodable {
        let message: String
    }
}
