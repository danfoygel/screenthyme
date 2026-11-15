import Foundation
import Testing
@testable import ThymeCore

struct JournalTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "journal-\(UUID().uuidString)")

    @Test func appendReadAndPending() throws {
        let journal = Journal(directory: directory, calendar: utc)
        let first = JournalEntry(kind: .threshold, activity: "a", event: "t.1", at: at(10, 1))
        let second = JournalEntry(kind: .threshold, activity: "a", event: "t.2", at: at(10, 2))
        try journal.append(first)
        try journal.append(second)
        #expect(journal.entries(on: testDay) == [first, second])
        #expect(journal.days() == [testDay])

        try journal.markUploaded([first.id], on: testDay)
        #expect(journal.pending(days: 1, now: at(12, 0)).map(\.id) == [second.id])
        #expect(journal.lastThresholdAt() == second.at)
    }

    @Test func skipsTornLastLine() throws {
        let journal = Journal(directory: directory, calendar: utc)
        let entry = JournalEntry(kind: .threshold, activity: "a", event: "t.1", at: at(9, 0))
        try journal.append(entry)
        let url = directory.appending(path: "journal-\(testDay).jsonl")
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data("{\"id\":\"trunc".utf8))
        try handle.close()
        #expect(journal.entries(on: testDay) == [entry])
    }

    @Test func splitsFilesByDay() throws {
        let journal = Journal(directory: directory, calendar: utc)
        try journal.append(JournalEntry(kind: .threshold, activity: "a", event: "t.1", at: at(23, 59)))
        try journal.append(JournalEntry(kind: .threshold, activity: "a", event: "t.1", at: at(24, 1)))
        #expect(journal.days() == [testDay, testDay.adding(days: 1, calendar: utc)])
    }
}
