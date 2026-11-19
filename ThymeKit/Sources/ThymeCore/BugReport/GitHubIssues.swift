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
            "message": "Bug report from \(report.kidName): \(screenshot)",
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

    public static func title(of report: BugReport) -> String {
        "\(report.kidName): \(report.summary)"
    }

    public static func body(of report: BugReport) -> String {
        var parts: [String] = []
        let text = report.text.trimmingCharacters(in: .whitespacesAndNewlines)
        parts.append(text.isEmpty ? "_No description._" : text)
        let images = report.screenshots.enumerated().compactMap { index, name in
            report.uploaded[name].map { "![Screenshot \(index + 1)](\(rawURL($0)))" }
        }
        if !images.isEmpty { parts.append(images.joined(separator: "\n")) }
        let rows = [BugReport.Detail("Kid", report.kidName)] + report.details
        parts.append((["| | |", "|---|---|"] + rows.map { "| \(cell($0.label)) | \(cell($0.value)) |" })
            .joined(separator: "\n"))
        if !report.log.isEmpty {
            let log = report.log.map { $0.replacingOccurrences(of: "````", with: "'''") }.joined(separator: "\n")
            parts.append("<details><summary>Recent log</summary>\n\n````\n\(log)\n````\n</details>")
        }
        parts.append("<sub>Filed by ScreenThyme on \(report.kidName)'s phone · report \(report.id.uuidString)</sub>")
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
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(tracker.repository)/\(endpoint)")!)
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

    private struct ContentsResult: Decodable {
        let content: ContentsItem
    }

    private struct Message: Decodable {
        let message: String
    }
}
