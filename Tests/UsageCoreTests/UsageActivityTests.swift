import XCTest
@testable import UsageCore

final class UsageActivityTests: XCTestCase {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func calendar(_ zone: String = "UTC") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }
    private func record(_ time: String, _ total: Int64) -> UsageRecord {
        .init(key: time, date: date(time), tokens: Tokens(input: total), session: "test")
    }

    func testSelectedPeriodsMatchSummaryTotalsAndExcludeFutureRecords() {
        let now = date("2026-10-09T16:00:00Z")
        var claude = ProviderUsage(provider: .claude, path: "")
        claude.records = [record("2026-09-09T23:59:59Z", 1000), // Outside 30 days.
                          record("2026-09-10T00:00:00Z", 100),
                          record("2026-10-02T23:59:59Z", 50), // Outside 7 days.
                          record("2026-10-03T00:00:00Z", 20),
                          record("2026-10-09T00:00:00Z", 10),
                          record("2026-10-09T16:00:00Z", 2000),
                          record("2026-10-09T18:00:00Z", 3000)]
        var codex = ProviderUsage(provider: .codex, path: "")
        codex.records = [record("2026-10-09T15:59:59Z", 5)]
        for (period, count, total) in [(UsagePeriod.today, 24, Int64(15)), (.week, 7, 35), (.thirtyDays, 30, 185)] {
            let buckets = UsageActivity.buckets(providers: [claude, codex], period: period, now: now, calendar: calendar())
            XCTAssertEqual(buckets.count, count)
            XCTAssertEqual(buckets.reduce(0) { $0 + $1.total }, total)
            for provider in [claude, codex] {
                XCTAssertEqual(buckets.reduce(Int64(0)) { $0 + ($1.amounts[provider.provider]?.total ?? 0) },
                               provider.tokens(since: period.start(at: now, calendar: calendar()), until: now).total)
            }
        }
    }

    func testHourlyBoundariesAndEmptySlots() {
        var usage = ProviderUsage(provider: .claude, path: "")
        usage.records = [record("2026-10-09T00:59:59Z", 10), record("2026-10-09T01:00:00Z", 20)]
        let buckets = UsageActivity.buckets(providers: [usage], period: .today,
                                           now: date("2026-10-09T16:00:00Z"), calendar: calendar())
        XCTAssertEqual(buckets[0].total, 10)
        XCTAssertEqual(buckets[1].total, 20)
        XCTAssertTrue(buckets.dropFirst(2).allSatisfy { $0.total == 0 })
        XCTAssertEqual(buckets.first?.start, date("2026-10-09T00:00:00Z"))
        XCTAssertEqual(buckets.last?.end, date("2026-10-10T00:00:00Z"))
    }

    func testTodayHandlesBothDaylightSavingTransitions() {
        let london = calendar("Europe/London")
        let spring = UsageActivity.buckets(providers: [], period: .today,
                                          now: date("2026-03-29T12:00:00Z"), calendar: london)
        XCTAssertEqual(spring.count, 23)
        var usage = ProviderUsage(provider: .codex, path: "")
        usage.records = [record("2026-10-25T00:30:00Z", 10), record("2026-10-25T01:30:00Z", 20)]
        let autumn = UsageActivity.buckets(providers: [usage], period: .today,
                                          now: date("2026-10-25T12:00:00Z"), calendar: london)
        XCTAssertEqual(autumn.count, 25)
        let repeatedHour = autumn.filter { london.component(.hour, from: $0.start) == 1 }
        XCTAssertEqual(repeatedHour.map(\.total), [10, 20])
        XCTAssertEqual(Set(autumn.map(\.id)).count, 25)
    }
}
