import Foundation
import Testing
@testable import ThymeCore

struct RawRecordLogTests {
    let log = RawRecordLog(directory: FileManager.default.temporaryDirectory.appending(path: "raw-\(UUID().uuidString)"))

    func record(_ name: String, _ payload: String) -> RawRecord {
        RawRecord(name: name, type: "Kid", payload: Data(payload.utf8))
    }

    @Test func holdsTheLastVersionOfEachRecordWithoutDeletedOnes() {
        log.append([record("Kid.a", "1"), record("Kid.b", "1")])
        log.append([record("Kid.a", "2"), .deletion("Kid.b"), record("Kid.c", "1")])
        #expect(log.records() == [record("Kid.a", "2"), record("Kid.c", "1")])
    }

    @Test func coversTheZoneOnlyFromAFullFetchAndAtTheTokenItKept() {
        let token = Data("t1".utf8)
        log.append([record("Kid.a", "1")])
        log.fetched(token: token)
        // Records fetched before a full fetch may not be all of them, nor one resumed that began without the log.
        log.markComplete()
        #expect(!log.covers(token: token))
        log.startFullFetch()
        log.append([record("Kid.a", "1")])
        log.fetched(token: token)
        log.markComplete()
        #expect(log.covers(token: token))
        // A build without the log fetched since: the token moved without it.
        #expect(!log.covers(token: Data("t2".utf8)))
        #expect(!log.covers(token: nil))
        log.startFullFetch()
        #expect(!log.covers(token: token))
        #expect(log.records().isEmpty)
    }

    @Test func compactsOnceOverwrittenLinesPileUp() {
        for version in 0..<5100 {
            log.append([record("Kid.a", "\(version)")])
        }
        #expect(log.state.lines < 5100)
        #expect(log.records() == [record("Kid.a", "5099")])
        log.startFullFetch()
        log.append([record("Kid.a", "1")])
        log.markComplete()
        log.compact()
        #expect(log.state.lines == 1)
        #expect(log.state.complete)
    }
}
