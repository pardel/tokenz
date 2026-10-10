import XCTest
@testable import UsageCore

final class UsageCoreTests: XCTestCase {
    let now = ISO8601DateFormatter().date(from: "2026-10-09T16:00:00Z")!
    let cutoff = ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z")!

    func line(_ row: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) }
    func claude(id: String = "msg-a", output: Int = 10, date: String = "2026-10-09T12:00:00Z") -> [String: Any] {
        ["type": "assistant", "timestamp": date, "sessionId": "session-a", "requestId": "req-a",
         "message": ["id": id, "usage": ["input_tokens": 20, "output_tokens": output,
                                               "cache_read_input_tokens": 100, "cache_creation_input_tokens": 50]]]
    }
    func codex(input: Int, output: Int, cached: Int = 0, lastInput: Int? = nil,
               date: String = "2026-10-09T12:00:00Z", quota: Bool = false) -> [String: Any] {
        var payload: [String: Any] = ["type": "token_count", "info": [
            "total_token_usage": ["input_tokens": input, "output_tokens": output, "cached_input_tokens": cached,
                                   "reasoning_output_tokens": output / 2],
            "last_token_usage": ["input_tokens": lastInput ?? input, "output_tokens": output, "cached_input_tokens": cached]]]
        if quota { payload["rate_limits"] = ["primary": ["used_percent": 62, "window_minutes": 10080, "resets_at": 1791967167]] }
        return ["type": "event_msg", "timestamp": date, "payload": payload]
    }

    func testClaudeDeduplicatesContentBlocksAndUsesFinalOutput() {
        var state = FileState()
        LogParser.consume(line(claude()), provider: .claude, state: &state, cutoff: cutoff)
        LogParser.consume(line(claude(output: 80)), provider: .claude, state: &state, cutoff: cutoff)
        LogParser.consume(line(claude(output: 5)), provider: .claude, state: &state, cutoff: cutoff)
        XCTAssertEqual(state.records.count, 1)
        XCTAssertEqual(state.records.values.first!.tokens, Tokens(input: 170, output: 80, cached: 100, cacheWrite: 50))
    }

    func testCodexCumulativeCountersRepeatedStatusesAndReasoning() {
        var state = FileState()
        for row in [codex(input: 100, output: 20, cached: 40), codex(input: 100, output: 20, cached: 40),
                    codex(input: 250, output: 40, cached: 90, date: "2026-10-09T13:00:00Z")] {
            LogParser.consume(line(row), provider: .codex, state: &state, cutoff: cutoff)
        }
        XCTAssertEqual(state.records.count, 2)
        let total = state.records.values.reduce(Tokens()) { $0 + $1.tokens }
        XCTAssertEqual(total, Tokens(input: 250, output: 40, cached: 90))
        XCTAssertEqual(total.total, 290) // Reasoning is already in output.
    }

    func testResumedCodexDoesNotCountInheritedHistory() {
        var state = FileState()
        LogParser.consume(line(codex(input: 50_000, output: 30, lastInput: 100)), provider: .codex, state: &state, cutoff: cutoff)
        XCTAssertEqual(state.records.values.first!.tokens.input, 100)
    }

    func testCodexResetAndOldBaselineCrossingMidnight() {
        var state = FileState()
        LogParser.consume(line(codex(input: 900, output: 90, date: "2026-09-30T23:00:00Z")), provider: .codex, state: &state, cutoff: cutoff)
        LogParser.consume(line(codex(input: 1000, output: 100, date: "2026-10-01T01:00:00Z")), provider: .codex, state: &state, cutoff: cutoff)
        XCTAssertEqual(state.records.values.first!.tokens.total, 110)
        LogParser.consume(line(codex(input: 20, output: 2, date: "2026-10-01T02:00:00Z")), provider: .codex, state: &state, cutoff: cutoff)
        XCTAssertEqual(state.records.values.reduce(Int64(0)) { $0 + $1.tokens.total }, 132)
    }

    func testLatestQuotaWithoutUsageAndExpiredWindow() {
        var state = FileState()
        var row = codex(input: 100, output: 10, quota: true)
        var payload = row["payload"] as! [String: Any]
        payload["info"] = NSNull(); row["payload"] = payload
        LogParser.consume(line(row), provider: .codex, state: &state, cutoff: cutoff)
        XCTAssertEqual(state.quota?.windows.first?.usedPercent, 62)
        XCTAssertEqual(state.quota?.windows.first?.label, "Weekly limit")
        XCTAssertTrue(state.quota!.windows[0].isExpired(at: .distantFuture))
        XCTAssertTrue(state.records.isEmpty)
    }

    func testMalformedAndNonUsageLinesAreIgnored() {
        var state = FileState()
        for data in [Data("bad JSON \"usage\"".utf8), line(["type": "user", "message": "text"]),
                     line(["type": "assistant", "message": ["usage": ["input_tokens": 2]]])] {
            LogParser.consume(data, provider: .claude, state: &state, cutoff: cutoff)
        }
        XCTAssertTrue(state.records.isEmpty)
    }

    func testCalendarPeriodsUseLocalMidnightAndRollingThirtyDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let midnight = UsagePeriod.today.start(at: now, calendar: calendar)
        XCTAssertEqual(ISO8601DateFormatter().string(from: midnight), "2026-10-08T23:00:00Z")
        XCTAssertEqual(calendar.component(.day, from: UsagePeriod.week.start(at: now, calendar: calendar)), 3)
        let thirtyDays = UsagePeriod.thirtyDays.start(at: now, calendar: calendar)
        XCTAssertEqual(calendar.component(.month, from: thirtyDays), 9)
        XCTAssertEqual(calendar.component(.day, from: thirtyDays), 10)
    }

    func testScannerIncrementalPartialLineDedupAndTruncation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.jsonl")
        let row = line(claude())
        var initial = row; initial.append(10)
        try initial.write(to: file)
        // Same message in a copied transcript must count once.
        try initial.write(to: root.appendingPathComponent("copied.jsonl"))
        let scanner = UsageScanner()
        let paths: [Provider: String] = [.claude: root.path, .codex: root.appendingPathComponent("missing").path]
        func total() -> Int64 { scanner.scan(paths: paths, now: now).providers[0].tokens(since: cutoff).total }
        XCTAssertEqual(total(), 180)
        XCTAssertEqual(total(), 180)
        let next = line(claude(id: "msg-b"))
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: next.prefix(next.count / 2))
        XCTAssertEqual(total(), 180) // Incomplete records wait for their writer.
        try handle.write(contentsOf: next.suffix(next.count - next.count / 2)); try handle.write(contentsOf: Data([10])); try handle.close()
        XCTAssertEqual(total(), 360)
        try Data().write(to: file)
        XCTAssertEqual(total(), 180) // Truncation removes the old file's contribution.
        XCTAssertNotNil(scanner.scan(paths: paths, now: now).providers[1].issue)
    }

    func testInputCacheIsSubsetAndTotalsHaveNoDoubleCounting() {
        let tokens = Tokens(input: 170, output: 10, cached: 100, cacheWrite: 50)
        XCTAssertEqual(tokens.uncached, 20)
        XCTAssertEqual(tokens.total, 180)
    }

    func testCopiedCodexForkHistoryIsNotCountedTwice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for id in ["original", "fork"] {
            var content = line(["type": "session_meta", "payload": ["id": id]])
            content.append(10)
            content.append(line(codex(input: 100, output: 20))); content.append(10)
            if id == "fork" {
                content.append(line(codex(input: 250, output: 40, date: "2026-10-09T13:00:00Z"))); content.append(10)
            }
            try content.write(to: root.appendingPathComponent("\(id).jsonl"))
        }
        let usage = UsageScanner().scan(paths: [.codex: root.path], now: now).providers[1]
        XCTAssertEqual(usage.records.count, 2)
        XCTAssertEqual(usage.tokens(since: cutoff).total, 290)
    }

    func testClaudePeriodsAreIndependentAndExcludeExpiredWindows() {
        let report = ClaudeQuotaReader.parse([
            "five_hour": ["used_percentage": 37, "resets_at": now.addingTimeInterval(100).timeIntervalSince1970],
            "seven_day": ["used_percentage": 87, "resets_at": now.addingTimeInterval(1000).timeIntervalSince1970]
        ], reportedAt: now)!
        XCTAssertEqual(report.activeWindow(minutes: 300, at: now)?.usedPercent, 37)
        XCTAssertEqual(report.activeWindow(minutes: 10080, at: now)?.usedPercent, 87)
        XCTAssertNil(report.activeWindow(minutes: 300, at: now.addingTimeInterval(100)))
        XCTAssertEqual(report.activeWindow(minutes: 10080, at: now.addingTimeInterval(100))?.usedPercent, 87)
        XCTAssertNil(report.activeWindow(minutes: 10080, at: now.addingTimeInterval(2000)))
        XCTAssertNil(ClaudeQuotaReader.parse(["five_hour": ["used_percentage": NSNull()]], reportedAt: now))
        XCTAssertNil(ClaudeQuotaReader.parse([:], reportedAt: now))
    }

    func testMissingPeriodNeverSubstitutesAnotherWindow() {
        let report = QuotaSnapshot(date: now, windows: [
            QuotaWindow(id: "weekly", usedPercent: 64, minutes: 10080, resetsAt: now.addingTimeInterval(1000)),
            QuotaWindow(id: "other", usedPercent: 20, minutes: 60, resetsAt: now.addingTimeInterval(1000))
        ])
        XCTAssertNil(report.activeWindow(minutes: 300, at: now))
        XCTAssertEqual(report.activeWindow(minutes: 10080, at: now)?.usedPercent, 64)
    }
}
