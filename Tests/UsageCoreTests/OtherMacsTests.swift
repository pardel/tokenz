import XCTest
@testable import UsageCore

final class OtherMacsTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tokenz-other-macs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    func write(_ name: String, _ lines: [String], modified: Date? = nil) throws {
        let url = folder.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
    }
    func record(_ when: String, _ tokens: Tokens) -> UsageRecord {
        UsageRecord(key: when, date: date(when), tokens: tokens, session: "s")
    }

    func testExportReadsBackAsTheSameDailyTotals() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        var claude = ProviderUsage(provider: .claude, path: "")
        claude.records = [record("2026-10-13T09:00:00Z", Tokens(input: 170, output: 80, cached: 100, cacheWrite: 50)),
                          record("2026-10-13T23:30:00Z", Tokens(input: 10, output: 5)),
                          record("2026-10-14T01:00:00Z", Tokens(input: 20, output: 2, cached: 5))]
        var codex = ProviderUsage(provider: .codex, path: "")
        codex.records = [record("2026-10-14T12:00:00Z", Tokens(input: 250, output: 40, cached: 90))]
        let text = UsageCSV.export([claude, codex], calendar: calendar)
        XCTAssertEqual(text, [UsageCSV.header, "2026-10-13,claude,180,85,100,50,265", "2026-10-14,claude,20,2,5,0,22",
                              "2026-10-14,codex,250,40,90,0,290"].joined(separator: "\n") + "\n")
        let days = try UsageCSV.parse(text)
        XCTAssertEqual(days["2026-10-13"]?[.claude], Tokens(input: 180, output: 85, cached: 100, cacheWrite: 50))
        XCTAssertEqual(days["2026-10-14"]?[.codex], Tokens(input: 250, output: 40, cached: 90))
    }

    func testEachMacsTotalsByPeriodAndWhenItsFileChanged() throws {
        let asOf = date("2026-10-14T13:12:00Z")
        try write("mini26.csv", [UsageCSV.header, "2026-10-07,claude,1000,0,900,0,1000", "2026-10-13,claude,7,0,6,0,7",
                                 "2026-10-14,claude,120,30,100,0,150", "2026-10-14,codex,40,10,30,0,50",
                                 "2026-10-14,copilot,5,5,0,0,10"], modified: asOf)
        let others = OtherMacsReader.read(folder: folder.path, thisMac: [])
        XCTAssertEqual(others.issues, [])
        XCTAssertEqual(others.machines.map(\.name), ["mini26"])
        let machine = others.machines[0]
        XCTAssertEqual(machine.asOf, asOf)
        let now = date("2026-10-14T15:00:00Z")
        let today = date("2026-10-14T00:00:00Z"), week = date("2026-10-08T00:00:00Z")
        XCTAssertEqual(machine.tokens(since: today, until: now, timeZone: utc), Tokens(input: 160, output: 40, cached: 130))
        XCTAssertEqual(machine.tokens(.codex, since: today, until: now, timeZone: utc).total, 50)
        // 10-07 is before the week; the Copilot row has no provider in Tokenz.
        XCTAssertEqual(machine.tokens(since: week, until: now, timeZone: utc).total, 207)
    }

    func testThisMacsOwnFileIsSkippedWhateverItsCase() throws {
        try write("Twenty5.csv", [UsageCSV.header, "2026-10-14,claude,7,0,6,0,7"])
        try write("mini26.csv", [UsageCSV.header])
        try write("notes.txt", ["not a Mac"])
        let others = OtherMacsReader.read(folder: folder.path, thisMac: ["twenty5"])
        XCTAssertEqual(others.machines.map(\.name), ["mini26"])
        XCTAssertEqual(others.issues, [])
    }

    func testAFileNotWhollyInTheFormatIsLeftOutAndNamed() throws {
        try write("a.csv", ["date,provider,tokens", "2026-10-14,claude,7"])
        try write("b.csv", [UsageCSV.header, "2026-10-14,claude,7,0,6,0,7", "2026-10-14,codex,7,0,6,0,8"])
        try write("c.csv", [UsageCSV.header, "2026-10-14,claude,7,0,6,0,7", "2026-10-14,claude,7,0,6,0,7"])
        try write("d.csv", [UsageCSV.header, "2026-02-30,claude,7,0,6,0,7"])
        try write("e.csv", [UsageCSV.header, "2026-10-14,claude,-7,0,6,0,-7"])
        try write("f.csv", [UsageCSV.header, "2026-10-14,claude,7,0,6,0"])
        try write("g.csv", [UsageCSV.header, "2026-10-14,claude,7,0,6,0,7"])
        let others = OtherMacsReader.read(folder: folder.path, thisMac: [])
        XCTAssertEqual(others.machines.map(\.name), ["g"])
        XCTAssertEqual(others.issues, [
            "a.csv is not a Tokenz CSV export, so a is left out.",
            "b.csv, line 3, is not a day's totals, so b is left out.",
            "c.csv, line 3, is not a day's totals, so c is left out.",
            "d.csv, line 2, is not a day's totals, so d is left out.",
            "e.csv, line 2, is not a day's totals, so e is left out.",
            "f.csv, line 2, is not a day's totals, so f is left out."])
    }

    func testTheScanReadsTheFolderOnlyWhenGivenOne() throws {
        try write("mini26.csv", [UsageCSV.header, "2026-10-14,claude,7,0,6,0,7"])
        let none = folder.appendingPathComponent("no-logs").path
        let paths: [Provider: String] = [.claude: none, .codex: none]
        XCTAssertNil(UsageScanner().scan(paths: paths).otherMacs)
        XCTAssertEqual(UsageScanner().scan(paths: paths, otherMacsPath: folder.path).otherMacs?.machines.map(\.name), ["mini26"])
        let missing = OtherMacsReader.read(folder: folder.appendingPathComponent("absent").path, thisMac: [])
        XCTAssertTrue(missing.isEmpty)
    }
}
