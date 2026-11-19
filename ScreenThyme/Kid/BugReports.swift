import CloudKit
import Foundation
import Observation
import ThymeCore
import UIKit

/// A kid's bug reports (PLAN.md §18), queued in Application Support with their screenshots until this phone files
/// them on GitHub. Sent at once, then again at every launch and background refresh until they're filed.
@MainActor @Observable
final class BugReportQueue {
    /// Newest first.
    private(set) var reports: [BugReport] = []
    private(set) var isSending = false
    /// Why waiting reports weren't filed at the last attempt, when it's nothing about one report.
    private(set) var waitingReason: String?

    /// Filed reports kept for the list; their screenshots are deleted once on GitHub.
    static let filedKept = 20
    @ObservationIgnored private let directory = URL.applicationSupportDirectory.appending(path: "BugReports")
    private var listURL: URL { directory.appending(path: "reports.json") }

    init() {
        reports = (try? Data(contentsOf: listURL)).flatMap { try? JSONDecoder.thyme.decode([BugReport].self, from: $0) } ?? []
    }

    func add(text: String, screenshots: [Data], kid: Kid, details: [BugReport.Detail], log: [String]) throws {
        var report = BugReport(kidID: kid.id, kidName: kid.displayName, at: Date(), text: text, details: details, log: log)
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
        if report.isFiled { return "Sent" }
        if isSending { return "Sending…" }
        return report.lastError ?? waitingReason ?? "Waiting to send"
    }

    /// Files every waiting report, oldest first. Stops at the first failure: the rest would fail the same way.
    func send(store: CloudStore?) async {
        guard !isSending, reports.contains(where: { !$0.isFiled }) else { return }
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
        prune()
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
    /// What a developer needs to know about this phone, as it is now.
    func bugReportDetails(now: Date = Date()) -> [BugReport.Detail] {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        var details: [BugReport.Detail] = [
            .init("Sent", now.formatted(Date.ISO8601FormatStyle(timeZone: .current))),
            .init("App version", version),
        ]
        // The version never changes between development builds; the executable's date tells them apart.
        if let url = Bundle.main.executableURL,
           let built = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            details.append(.init("Built", built.formatted(Date.ISO8601FormatStyle(timeZone: .current))))
        }
        details += [
            .init("iOS", UIDevice.current.systemVersion),
            .init("Phone", Self.hardwareModel),
            .init("Screen Time access", authorizationLabel),
            .init("Monitoring", monitoringLabel),
            .init("Last wake", AppGroup.journal.lastThresholdAt().map { $0.formatted(Date.ISO8601FormatStyle(timeZone: .current)) } ?? "none yet"),
            .init("Waiting to upload", "\(Uploader.backlogCount())"),
            .init("Parent phone nearby", nearby.summary),
        ]
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
