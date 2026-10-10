import XCTest
@testable import UsageCore

final class ClaudeStatusLineSetupTests: XCTestCase {
    typealias Setup = ClaudeStatusLineSetup
    var root: URL!
    var config: URL!
    var settings: URL { config.appendingPathComponent("settings.json") }
    var installedScript: URL { config.appendingPathComponent(Setup.scriptName) }
    var source: URL!
    let scriptText = "#!/bin/zsh\nprint -r -- Claude\n"
    /// The temporary root stands in for home, so commands take the `~/.claude/…` form.
    var home: String { root.path }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenz tests \(UUID().uuidString)")
        config = root.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        source = root.appendingPathComponent("source.sh")
        try Data(scriptText.utf8).write(to: source)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func write(_ text: String, permissions: Int = 0o644) throws {
        try Data(text.utf8).write(to: settings)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: settings.path)
    }
    func read(_ url: URL) throws -> String { String(decoding: try Data(contentsOf: url), as: UTF8.self) }
    func bytes(_ url: URL) throws -> Data { try Data(contentsOf: url) }
    func permissions(_ url: URL) throws -> Int {
        try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! Int
    }
    var state: Setup.State { Setup.state(configDirectory: config, home: home) }
    var entry: String { Setup.entry("~/.claude/tokenz-statusline.sh") }

    func testStates() throws {
        XCTAssertEqual(state, .available, "no settings.json")
        try write(#"{"model": "opus"}"#)
        XCTAssertEqual(state, .available, "no statusLine key")
        try write("not json")
        XCTAssertEqual(state, .unreadable)
        try write("[1, 2]")
        XCTAssertEqual(state, .unreadable, "not an object")
        try write(#"{"statusLine": {"type": "command", "command": "/usr/bin/true"}}"#)
        XCTAssertEqual(state, .existing("/usr/bin/true"))
        try write(#"{"statusLine": {"type": "command"}}"#)
        XCTAssertEqual(state, .existing(""))
        try write(#"{"statusLine": {"type": "command", "command": "~/.claude/tokenz-statusline.sh"}}"#)
        XCTAssertEqual(state, .installed)
        try write(#"{"statusLine": {"type": "command", "command": "$HOME/.claude/tokenz-statusline.sh"}}"#)
        XCTAssertEqual(state, .installed)
        try write(#"{"statusLine": {"command": "'\#(installedScript.path)'", "type": "command"}}"#)
        XCTAssertEqual(state, .installed, "absolute path, quoted")
        try write(#"{"statusLine": {"command": "\#(installedScript.path)", "type": "command"}}"#)
        XCTAssertEqual(state, .chained, "unquoted path with spaces: not ours to remove, but it feeds Tokenz")
    }

    func testChainedStatusLineScriptIsDetected() throws {
        let own = config.appendingPathComponent("statusline_extended.sh")
        try Data("#!/bin/bash\ninput=$(cat)\n\(Setup.chainLine(configDirectory: config, home: home))\necho hi\n".utf8).write(to: own)
        try write(#"{"statusLine": {"type": "command", "command": "~/.claude/statusline_extended.sh"}}"#)
        XCTAssertEqual(state, .chained)
        try write(#"{"statusLine": {"type": "command", "command": "bash ~/.claude/statusline_extended.sh --flag"}}"#)
        XCTAssertEqual(state, .chained, "through an interpreter")
        try Data("#!/bin/bash\necho hi\n".utf8).write(to: own)
        XCTAssertEqual(state, .existing("bash ~/.claude/statusline_extended.sh --flag"))
    }

    func testCommandAndChainLine() {
        XCTAssertEqual(Setup.command(configDirectory: config, home: home), "~/.claude/tokenz-statusline.sh")
        XCTAssertEqual(Setup.chainLine(configDirectory: config, home: home),
                       #"printf '%s\n' "$input" | ~/.claude/tokenz-statusline.sh > /dev/null"#)
        let elsewhere = URL(fileURLWithPath: "/Volumes/Work Disk/claude")
        XCTAssertEqual(Setup.command(configDirectory: elsewhere, home: "/Users/someone"),
                       "'/Volumes/Work Disk/claude/tokenz-statusline.sh'")
        XCTAssertEqual(Setup.command(configDirectory: URL(fileURLWithPath: "/opt/claude"), home: "/Users/someone"),
                       "/opt/claude/tokenz-statusline.sh")
    }

    func testInstallIntoNoFileThenRemove() throws {
        try Setup.install(configDirectory: config, script: source, home: home)
        XCTAssertEqual(state, .installed)
        XCTAssertEqual(try read(settings), "{\n  \(entry)\n}\n")
        XCTAssertEqual(try permissions(settings), 0o600)
        XCTAssertEqual(try read(installedScript), scriptText)
        XCTAssertEqual(try permissions(installedScript), 0o755)
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.appendingPathComponent(Setup.backupName).path))
        try Setup.remove(configDirectory: config, home: home)
        XCTAssertEqual(try read(settings), "{}\n")
        XCTAssertEqual(state, .available)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedScript.path))
    }

    func testInstallIntoEmptyObjectThenRemove() throws {
        for original in ["{}", "{}\n", "{\n}\n", "  { }"] {
            try write(original)
            try Setup.install(configDirectory: config, script: source, home: home)
            XCTAssertEqual(state, .installed, original)
            XCTAssertEqual(try read(config.appendingPathComponent(Setup.backupName)), original)
            try Setup.remove(configDirectory: config, home: home)
            XCTAssertEqual(try read(settings), original, "remove restores the original bytes")
        }
    }

    func testInstallPreservesFormattingAndRemoveRestoresBytes() throws {
        let originals = [
            "{\n    \"model\" :  \"opus\",\n\t\"env\": {\"A\": \"1\"},\n  \"n\": 1.50\n}\n",
            "{\"model\":\"opus\",\"hooks\":{}}",
            "\u{FEFF}{\r\n  \"model\": \"opus\"\r\n}\r\n",
        ]
        for original in originals {
            try write(original, permissions: 0o644)
            try Setup.install(configDirectory: config, script: source, home: home)
            let installed = try bytes(settings)
            let brace = original.firstIndex(of: "{")!
            let lead = String(original[original.index(after: brace)...].prefix(while: { $0.isWhitespace }))
            let insertion = lead + entry + ","
            XCTAssertEqual(installed, Data((String(original[...brace]) + insertion + original[original.index(after: brace)...]).utf8),
                           "only the entry is added")
            XCTAssertEqual(try permissions(settings), 0o644, "permissions kept")
            XCTAssertEqual(try bytes(config.appendingPathComponent(Setup.backupName)), Data(original.utf8))
            XCTAssertEqual(state, .installed)
            try Setup.remove(configDirectory: config, home: home)
            XCTAssertEqual(try bytes(settings), Data(original.utf8), "byte for byte")
        }
    }

    func testInstallRefusedOverExistingOrUnreadableSettings() throws {
        for (original, expected) in [(#"{"statusLine": {"type": "command", "command": "/usr/bin/true"}}"#, Setup.State.existing("/usr/bin/true")),
                                     ("{ broken", .unreadable)] {
            try write(original)
            XCTAssertThrowsError(try Setup.install(configDirectory: config, script: source, home: home)) { error in
                XCTAssertEqual(error as? Setup.SetupError, .notAllowed(expected))
            }
            XCTAssertEqual(try read(settings), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: installedScript.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: config.appendingPathComponent(Setup.backupName).path))
        }
    }

    func testInstallScriptOnlyLeavesSettingsAlone() throws {
        XCTAssertThrowsError(try Setup.installScriptOnly(configDirectory: config, script: source, home: home))
        let original = #"{"statusLine": {"type": "command", "command": "/usr/bin/true"}}"#
        try write(original)
        try Setup.installScriptOnly(configDirectory: config, script: source, home: home)
        XCTAssertEqual(try read(settings), original)
        XCTAssertEqual(try read(installedScript), scriptText)
        XCTAssertEqual(try permissions(installedScript), 0o755)
        XCTAssertThrowsError(try Setup.remove(configDirectory: config, home: home), "remove only undoes Tokenz's own entry")
    }

    func testMissingScriptWritesNothing() throws {
        try write("{}")
        let missing = root.appendingPathComponent("missing.sh")
        XCTAssertThrowsError(try Setup.install(configDirectory: config, script: missing, home: home)) { error in
            XCTAssertEqual(error as? Setup.SetupError, .scriptMissing)
        }
        XCTAssertEqual(try read(settings), "{}")
        XCTAssertEqual(state, .available)
    }

    func testRemoveAfterEditsFallsBackToRewrite() throws {
        try write("{\n  \"model\": \"opus\"\n}\n")
        try Setup.install(configDirectory: config, script: source, home: home)
        try Data(#"{"statusLine":{"type":"command","command":"~/.claude/tokenz-statusline.sh"},"model":"sonnet","env":{"A":"1"}}"#.utf8).write(to: settings)
        let feed = config.appendingPathComponent("tokenz-rate-limits.json")
        try Data("{}".utf8).write(to: feed)
        try Setup.remove(configDirectory: config, home: home)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        XCTAssertNil(object["statusLine"])
        XCTAssertEqual(object["model"] as? String, "sonnet")
        XCTAssertEqual((object["env"] as? [String: String])?["A"], "1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: feed.path), "feed kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: config.appendingPathComponent(Setup.backupName).path), "backup kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedScript.path))
    }

    func testAbsoluteCommandWhenOutsideHome() throws {
        try Setup.install(configDirectory: config, script: source, home: "/Users/nobody-here")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        let command = (object["statusLine"] as! [String: Any])["command"] as! String
        XCTAssertEqual(command, "'\(installedScript.path)'", "quoted, because the path has spaces")
        XCTAssertEqual(Setup.state(configDirectory: config, home: "/Users/nobody-here"), .installed)
        try Setup.remove(configDirectory: config, home: "/Users/nobody-here")
        XCTAssertEqual(try read(settings), "{}\n")
    }

    /// Every session runs the script, and one left idle passes on older limits.
    func testScriptKeepsTheSavedWindowAgainstOlderReadings() throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/\(Setup.scriptName)")
        let feed = root.appendingPathComponent("feed.json")
        let start = Date().timeIntervalSince1970.rounded()
        let reset = start + 3600, week = start + 86400
        func run(_ limits: [String: Any]?) throws {
            let process = Process(), input = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [script.path]
            process.environment = ProcessInfo.processInfo.environment.merging(["TOKENZ_FEED": feed.path]) { $1 }
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            var payload: [String: Any] = ["model": ["display_name": "Opus"]]
            payload["rate_limits"] = limits
            input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: payload))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        func window(_ used: Double, _ resetsAt: Double) -> [String: Any] { ["used_percentage": used, "resets_at": resetsAt] }
        func saved(_ key: String) throws -> Double? {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: feed)) as? [String: Any]
            return ((object?["rate_limits"] as? [String: Any])?[key] as? [String: Any])?["used_percentage"] as? Double
        }
        func inode() throws -> Int { try FileManager.default.attributesOfItem(atPath: feed.path)[.systemFileNumber] as! Int }

        try run(["five_hour": window(52, reset), "seven_day": window(37, week)])
        XCTAssertEqual(try saved("five_hour"), 52)
        XCTAssertEqual(try permissions(feed), 0o600)
        let written = try inode()
        try run(["five_hour": window(27, reset), "seven_day": window(30, week)])
        try run(["five_hour": window(90, start - 60)])
        try run(nil)
        XCTAssertEqual(try inode(), written, "older readings leave the file as it was")
        XCTAssertEqual(try saved("seven_day"), 37)
        try run(["five_hour": window(53.5, reset)])
        XCTAssertEqual(try saved("five_hour"), 53.5)
        XCTAssertEqual(try saved("seven_day"), 37, "a window the session did not report stays")
        try run(["five_hour": window(4, start + 1800)])
        XCTAssertEqual(try saved("five_hour"), 4, "another live window: another account, or limits reset early")
    }
}
