import Foundation
import Testing
@testable import ThymeCore

struct UsageReportTests {
    let youtube = UUID(), roblox = UUID()

    func sample(_ item: UUID, _ start: Date, _ end: Date, _ seconds: Double, reportedAt: Date?) -> UsageSample {
        UsageSample(id: UUID(), kidID: testKid.id, itemID: item, day: testDay, start: start, end: end, seconds: seconds,
                    reportedAt: reportedAt)
    }

    @Test func groupsByFetchInOrder() {
        let reports = UsageReport.reports([
            sample(youtube, at(13, 21), at(13, 23), 60, reportedAt: at(13, 23)),
            sample(youtube, at(13, 19), at(13, 21), 120, reportedAt: at(13, 21)),
            sample(roblox, at(13, 21), at(13, 23), 90, reportedAt: at(13, 23)),
        ])
        #expect(reports.map(\.at) == [at(13, 21), at(13, 23)])
        #expect(reports.last?.samples.map(\.itemID) == [roblox, youtube])
        #expect(reports.last?.seconds == 150)
        #expect(reports.allSatisfy { $0.exact })
    }

    /// A fetch just after the hour finds use in both hours; the earlier hour's sample ends at the hour.
    @Test func fetchSpanningAnHourIsOneReport() {
        let reports = UsageReport.reports([
            sample(youtube, at(13, 59), at(14, 0), 60, reportedAt: at(14, 1)),
            sample(youtube, at(14, 0), at(14, 1), 60, reportedAt: at(14, 1)),
        ])
        #expect(reports.count == 1)
        #expect(reports.first?.samples.count == 2)
    }

    @Test func oldSamplesFallBackToTheirEnd() {
        let reports = UsageReport.reports([sample(youtube, at(9, 0), at(9, 4), 240, reportedAt: nil)])
        #expect(reports.first?.at == at(9, 4))
        #expect(reports.first?.exact == false)
    }

    @Test func oldSamplesDecode() throws {
        let old = sample(youtube, at(9, 0), at(9, 4), 240, reportedAt: nil)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        json["reportedAt"] = nil
        let decoded = try JSONDecoder().decode(UsageSample.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == old)
    }
}
