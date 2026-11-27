import CloudKit
import Foundation
import Observation
import ThymeCore
import UIKit

/// This phone's bug reports, a kid's or a parent's (PLAN.md §18), queued in Application Support with their screenshots
/// until this phone files them on GitHub. Sent at once, then again at every launch and background refresh until they're filed.
/// When one is fixed, the repository's workflow pushes a notification to this phone (`PushPhone`, `Tools/BugPush`); the
/// list learns of it by looking the issues up.
@MainActor @Observable
final class BugReportQueue {
    /// Newest first.
    private(set) var reports: [BugReport] = []
    private(set) var isSending = false
    /// Why waiting reports weren't filed at the last attempt, when it's nothing about one report.
    private(set) var waitingReason: String?

    /// Filed reports kept for the list; their screenshots are deleted once on GitHub.
    static let filedKept = 20
    /// How often filed reports are looked up for a fix; launches and background refreshes come more often.
    static let checkInterval: TimeInterval = 30 * 60
    @ObservationIgnored private var checkedAt: Date?
    /// This phone's APNs device token (hex), from the app delegate; saved to the repository when it changes.
    @ObservationIgnored var pushToken: String? {
        didSet { if pushToken != oldValue, let store = AppModel.shared.store { Task { await sync(store: store) } } }
    }
    /// The app's `aps-environment` (project.yml): every build is a development build.
    static let pushEnvironment = "development"
    /// Names this phone in its reports and its push token's file in the repository.
    static let phoneID: UUID = {
        let key = "bugReportPhoneID"
        if let saved = UserDefaults.standard.string(forKey: key).flatMap(UUID.init) { return saved }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }()
    /// The token last saved to the repository.
    private static let savedTokenKey = "bugReportSavedPushToken"
    @ObservationIgnored private let directory = URL.applicationSupportDirectory.appending(path: "BugReports")
    private var listURL: URL { directory.appending(path: "reports.json") }

    init() {
        reports = (try? Data(contentsOf: listURL)).flatMap { try? JSONDecoder.thyme.decode([BugReport].self, from: $0) } ?? []
    }

    func add(kind: BugReport.Kind, text: String, screenshots: [Data], reporter: String, kidID: UUID?,
             details: [BugReport.Detail], log: [String]) throws {
        var report = BugReport(kind: kind, kidID: kidID, reporter: reporter, at: Date(), text: text, details: details, log: log,
                               phoneID: Self.phoneID)
        let folder = folder(of: report)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, data) in screenshots.enumerated() {
            let name = "\(index + 1).jpg"
            try data.write(to: folder.appending(path: name),
                           options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            report.screenshots.append(name)
        }
        reports.insert(report, at: 0)
        save()
    }

    /// Drops a report that hasn't been filed yet.
    func remove(_ report: BugReport) {
        reports.removeAll { $0.id == report.id }
        try? FileManager.default.removeItem(at: folder(of: report))
        save()
    }

    func status(of report: BugReport) -> String {
        switch report.resolution {
        case .fixed: return (report.kind ?? .bug).doneStatus
        case .closed: return "Closed"
        case nil: break
        }
        if report.isFiled { return "Sent" }
        if isSending { return "Sending…" }
        return report.lastError ?? waitingReason ?? "Waiting to send"
    }

    /// Saves a new push token while reports wait for a fix, files every waiting report, then looks on GitHub for fixes
    /// to filed ones (at most every `checkInterval`, unless `checkNow`).
    func sync(store: CloudStore?, checkNow: Bool = false) async {
        let waiting = reports.contains { !$0.isFiled }
        let newToken = pushToken.flatMap { $0 == UserDefaults.standard.string(forKey: Self.savedTokenKey) ? nil : $0 }
        let registering = newToken != nil && reports.contains { !$0.isFiled || $0.awaitsFix }
        let checking = reports.contains(where: \.awaitsFix)
            && (checkNow || checkedAt.map { Date().timeIntervalSince($0) >= Self.checkInterval } ?? true)
        guard !isSending, waiting || registering || checking else { return }
        guard let store else {
            waitingReason = "Waiting: this phone hasn't joined a family"
            return
        }
        isSending = true
        defer { isSending = false }
        let tracker: IssueTracker?
        do {
            tracker = try await IssueTrackerService.fetch(store: store)
        } catch {
            waitingReason = Self.describe(error)
            return
        }
        guard let tracker, tracker.isUsable else {
            waitingReason = "Waiting for a parent to set up bug reports"
            return
        }
        waitingReason = nil
        let github = GitHubIssues(tracker: tracker)
        if registering, let newToken { await savePushToken(newToken, with: github) }
        if waiting { await file(with: github) }
        if checking { await checkFixes(with: github) }
        prune()
    }

    /// Oldest first. Stops at the first failure: the rest would fail the same way.
    private func file(with github: GitHubIssues) async {
        for id in reports.filter({ !$0.isFiled }).reversed().map(\.id) {
            guard var report = reports.first(where: { $0.id == id }) else { continue }
            do {
                for name in report.screenshots where report.uploaded[name] == nil {
                    // A screenshot that's gone (the phone ran out of space?) is left out rather than holding up the rest.
                    guard let data = try? Data(contentsOf: folder(of: report).appending(path: name)) else { continue }
                    report.uploaded[name] = try await github.upload(data, screenshot: name, of: report)
                    update(report)
                }
                let issue = try await github.openIssue(for: report)
                report.issueURL = issue
                report.lastError = nil
                update(report)
                try? FileManager.default.removeItem(at: folder(of: report))
                try? AppGroup.journal.append(.note("bug report filed: issue \(issue.lastPathComponent)"))
            } catch {
                report.lastError = Self.describe(error)
                update(report)
                try? AppGroup.journal.append(.note("bug report not filed: \(error)"))
                break
            }
        }
    }

    /// A failure is retried at the next sync; it doesn't hold up filing.
    private func savePushToken(_ token: String, with github: GitHubIssues) async {
        let phone = PushPhone(token: token, topic: Bundle.main.bundleIdentifier ?? "", environment: Self.pushEnvironment,
                              updatedAt: Date())
        do {
            try await github.save(phone, id: Self.phoneID)
            UserDefaults.standard.set(token, forKey: Self.savedTokenKey)
            try? AppGroup.journal.append(.note("bug reports: push token saved"))
        } catch {
            try? AppGroup.journal.append(.note("bug reports: push token not saved: \(error)"))
        }
    }

    /// For the list's "Fixed" (the reporter has heard by push). An issue GitHub won't show (deleted, or the token
    /// changed) is skipped; no internet stops the check until next time.
    private func checkFixes(with github: GitHubIssues) async {
        for id in reports.filter(\.awaitsFix).map(\.id) {
            guard var report = reports.first(where: { $0.id == id }), let issue = report.issueURL else { continue }
            do {
                report.resolution = try await github.resolution(of: issue)
            } catch is GitHubIssues.Failure {
                continue
            } catch {
                return
            }
            guard report != reports.first(where: { $0.id == id }) else { continue }
            update(report)
            if report.resolution == .fixed {
                try? AppGroup.journal.append(.note("bug report fixed: issue \(issue.lastPathComponent)"))
            }
        }
        checkedAt = Date()
    }

    func screenshot(_ name: String, of report: BugReport) -> UIImage? {
        UIImage(contentsOfFile: folder(of: report).appending(path: name).path)
    }

    private static func describe(_ error: any Error) -> String {
        if let error = error as? CKError, error.isOffline { return "Waiting for the internet" }
        if error is URLError { return "Waiting for the internet" }
        return error.localizedDescription
    }

    private func folder(of report: BugReport) -> URL {
        directory.appending(path: report.id.uuidString)
    }

    private func update(_ report: BugReport) {
        guard let index = reports.firstIndex(where: { $0.id == report.id }) else { return }
        reports[index] = report
        save()
    }

    private func prune() {
        let filed = reports.filter(\.isFiled)
        guard filed.count > Self.filedKept else { return }
        let dropped = Set(filed.dropFirst(Self.filedKept).map(\.id))
        reports.removeAll { dropped.contains($0.id) }
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder.thyme.encode(reports)
            .write(to: listURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

extension AppModel {
    /// Who a report is from: the kid on a kid's phone, the parent's name on a parent's.
    var bugReporter: (name: String, kidID: UUID?) {
        switch config.role {
        case .kid: (config.kid?.displayName ?? "A kid", config.kid?.id)
        case .parent: (config.parentName.flatMap { $0.isEmpty ? nil : $0 } ?? "A parent", nil)
        case .unset: ("A phone not set up yet", nil)
        }
    }

    /// What a developer needs to know about this phone, as it is now, and the screen the report was started from.
    func bugReportDetails(screen: String?, now: Date = Date()) -> [BugReport.Detail] {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        let format = Date.ISO8601FormatStyle(timeZone: .current)
        var details: [BugReport.Detail] = [
            .init("Sent", now.formatted(format)),
            .init("Phone's role", config.role.rawValue + (config.testMode ? " (test mode)" : "")),
        ]
        if let screen { details.append(.init("Screen", screen)) }
        details.append(.init("App version", version))
        // The version never changes between development builds; the executable's date tells them apart.
        if let url = Bundle.main.executableURL,
           let built = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            details.append(.init("Built", built.formatted(format)))
        }
        details += [
            .init("iOS", UIDevice.current.systemVersion),
            .init("Phone", Self.hardwareModel),
            .init("Family", config.family.map { $0.isOwner ? "owner" : "joined" } ?? "not joined"),
        ]
        switch config.role {
        case .kid:
            details += [
                .init("Screen Time access", authorizationLabel),
                .init("Monitoring", monitoringLabel),
                .init("Last wake", AppGroup.journal.lastThresholdAt().map { $0.formatted(format) } ?? "none yet"),
                .init("Waiting to upload", "\(Uploader.backlogCount())"),
                .init("Parent phone nearby", nearby.summary),
            ]
        case .parent:
            details += [
                .init("Kids", "\(data.kids.count)"),
                .init("Waiting for the internet", "\(PendingSaves.count) changes"),
                .init("Kids' phones nearby", nearby.summary),
            ]
        case .unset:
            break
        }
        return details
    }

    /// The journal's notes from yesterday and today, newest last.
    static func bugReportLog(now: Date = Date(), limit: Int = 60) -> [String] {
        let journal = AppGroup.journal
        let today = DayKey(now, calendar: journal.calendar)
        let format = Date.ISO8601FormatStyle(timeZone: .current)
        let days = [today.adding(days: -1, calendar: journal.calendar), today]
        let notes: [JournalEntry] = days.flatMap { journal.entries(on: $0) }.filter { $0.kind == .note }
        return notes.sorted { $0.at < $1.at }.suffix(limit).map { entry in
            entry.at.formatted(format) + " " + (entry.event ?? "")
        }
    }

    /// Like "iPhone14,6" (an iPhone SE, 3rd generation).
    static var hardwareModel: String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
