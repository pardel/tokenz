import Foundation

/// Offers Tokenz's status line to Claude Code, which reports plan limits only to a
/// status line command. Writes happen only through `install`, `installScriptOnly`
/// and `remove`; never over a status line the user already has, and an existing
/// settings.json is backed up before it changes.
public enum ClaudeStatusLineSetup {
    public enum State: Equatable, Sendable {
        /// `statusLine.command` runs Tokenz's script.
        case installed
        /// The user's status line already passes its input to Tokenz's script.
        case chained
        /// The user has a status line of their own, shown with its command.
        case existing(String)
        /// No settings.json, or no `statusLine` in it.
        case available
        /// settings.json is not a readable JSON object. Never changed.
        case unreadable
    }

    public enum SetupError: Error, Equatable {
        case notAllowed(State)
        case scriptMissing
        case invalidSettings
    }

    public static let scriptName = "tokenz-statusline.sh"
    public static let backupName = "settings.json.tokenz-backup"

    public static var userHome: String { FileManager.default.homeDirectoryForCurrentUser.path }

    /// The Claude configuration folder: the parent of its `projects` folder.
    public static func configDirectory(projectsPath: String) -> URL {
        URL(fileURLWithPath: NSString(string: projectsPath).expandingTildeInPath).deletingLastPathComponent()
    }

    /// How the script is named in a shell command: `~/…` under home, quoted if needed.
    public static func command(configDirectory: URL, home: String = userHome) -> String {
        let path = configDirectory.appendingPathComponent(scriptName).path
        if path.hasPrefix(home + "/"), !path.dropFirst(home.count).contains(where: { " '\"\\$`".contains($0) }) {
            return "~" + path.dropFirst(home.count)
        }
        return path.contains(where: { !($0.isLetter || $0.isNumber || "/._-+~".contains($0)) })
            ? "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" : path
    }

    /// The line a user's own status line script adds, after it has read its input.
    public static func chainLine(configDirectory: URL, home: String = userHome) -> String {
        "printf '%s\\n' \"$input\" | \(command(configDirectory: configDirectory, home: home)) > /dev/null"
    }

    public static func state(configDirectory: URL, home: String = userHome) -> State {
        let settings = configDirectory.appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: settings.path) else { return .available }
        guard let data = try? Data(contentsOf: settings),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unreadable }
        guard let statusLine = object["statusLine"] else { return .available }
        guard let command = (statusLine as? [String: Any])?["command"] as? String else { return .existing("") }
        let script = configDirectory.appendingPathComponent(scriptName).standardizedFileURL.path
        let words = shellWords(command)
        if words.count == 1, expand(words[0], home: home) == script { return .installed }
        if command.contains(scriptName) { return .chained }
        // A status line script that pipes its input into Tokenz's script.
        for word in words.prefix(3) {
            let url = URL(fileURLWithPath: expand(word, home: home))
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])).flatMap({ $0.isRegularFile == true ? $0.fileSize : nil }),
               size <= 1_048_576, let text = try? String(contentsOf: url, encoding: .utf8), text.contains(scriptName) {
                return .chained
            }
        }
        return .existing(command)
    }

    /// Writes the script and adds Tokenz's `statusLine` to settings.json. Only from `.available`.
    public static func install(configDirectory: URL, script: URL, home: String = userHome) throws {
        let current = state(configDirectory: configDirectory, home: home)
        guard current == .available else { throw SetupError.notAllowed(current) }
        let settings = configDirectory.appendingPathComponent("settings.json")
        let ours = command(configDirectory: configDirectory, home: home)
        let original = try? Data(contentsOf: settings)
        let updated: Data
        var permissions: Int = 0o600
        if let original {
            guard let decoded = decode(original),
                  let inserted = insertingStatusLine(into: decoded.text, command: ours) else { throw SetupError.invalidSettings }
            updated = decoded.mark + Data(inserted.utf8)
            permissions = ((try? FileManager.default.attributesOfItem(atPath: settings.path))?[.posixPermissions] as? Int) ?? 0o600
        } else {
            updated = Data("{\n  \(entry(ours))\n}\n".utf8)
        }
        // Nothing is written unless the result is still an object whose statusLine is ours.
        guard isOurs(updated, command: ours) else { throw SetupError.invalidSettings }
        try writeScript(configDirectory: configDirectory, script: script)
        if let original {
            try writeAtomically(original, to: configDirectory.appendingPathComponent(backupName), permissions: permissions)
        }
        try writeAtomically(updated, to: settings, permissions: permissions)
    }

    /// Writes only the script, for users who keep their own status line.
    public static func installScriptOnly(configDirectory: URL, script: URL, home: String = userHome) throws {
        let current = state(configDirectory: configDirectory, home: home)
        guard case .existing = current else { throw SetupError.notAllowed(current) }
        try writeScript(configDirectory: configDirectory, script: script)
    }

    /// Removes Tokenz's `statusLine` and script. Only from `.installed`; the feed and the backup stay.
    public static func remove(configDirectory: URL, home: String = userHome) throws {
        let current = state(configDirectory: configDirectory, home: home)
        guard current == .installed else { throw SetupError.notAllowed(current) }
        let settings = configDirectory.appendingPathComponent("settings.json")
        let original = try Data(contentsOf: settings)
        let ours = command(configDirectory: configDirectory, home: home)
        var updated: Data?
        if let decoded = decode(original),
           let removed = removingStatusLine(from: decoded.text, command: ours) {
            updated = decoded.mark + Data(removed.utf8)
        }
        if updated.map({ !isValidWithoutStatusLine($0) }) ?? true {
            // Edited since install: rewrite without the key. Key order and spacing may change.
            guard var object = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                throw SetupError.invalidSettings
            }
            object["statusLine"] = nil
            updated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes]) + Data("\n".utf8)
        }
        guard let updated, isValidWithoutStatusLine(updated) else { throw SetupError.invalidSettings }
        let permissions = ((try? FileManager.default.attributesOfItem(atPath: settings.path))?[.posixPermissions] as? Int) ?? 0o600
        try writeAtomically(updated, to: settings, permissions: permissions)
        let script = configDirectory.appendingPathComponent(scriptName)
        if FileManager.default.fileExists(atPath: script.path) { try FileManager.default.removeItem(at: script) }
    }

    // MARK: - Text edits that keep the user's formatting

    /// UTF-8 text with any byte-order mark held apart, so it is written back unchanged.
    static func decode(_ data: Data) -> (mark: Data, text: String)? {
        let bom = Data([0xEF, 0xBB, 0xBF])
        let mark = data.starts(with: bom) ? bom : Data()
        guard let text = String(data: data.dropFirst(mark.count), encoding: .utf8) else { return nil }
        return (mark, text)
    }

    static func entry(_ command: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [command], options: [.withoutEscapingSlashes])
        let quoted = String(decoding: data, as: UTF8.self).dropFirst().dropLast()
        return "\"statusLine\": { \"type\": \"command\", \"command\": \(quoted) }"
    }

    /// Inserts the entry right after the opening brace, leaving every other byte as it was.
    static func insertingStatusLine(into text: String, command: String) -> String? {
        guard let brace = text.firstIndex(where: { !$0.isWhitespace && $0 != "\u{FEFF}" }), text[brace] == "{" else { return nil }
        let afterBrace = text.index(after: brace)
        let rest = text[afterBrace...]
        let lead = String(rest.prefix(while: { $0.isWhitespace }))
        let entry = entry(command)
        let insertion: String
        if rest.dropFirst(lead.count).first == "}" {
            insertion = "\n  " + entry + "\n" // Empty object.
        } else {
            insertion = lead + entry + ","
        }
        return String(text[..<afterBrace]) + insertion + rest
    }

    /// Removes exactly what `insertingStatusLine` added, or returns nil if it is no longer there.
    static func removingStatusLine(from text: String, command: String) -> String? {
        guard let brace = text.firstIndex(where: { !$0.isWhitespace && $0 != "\u{FEFF}" }), text[brace] == "{" else { return nil }
        let afterBrace = text.index(after: brace)
        let rest = String(text[afterBrace...])
        let lead = String(rest.prefix(while: { $0.isWhitespace }))
        let entry = entry(command)
        for insertion in [lead + entry + ",", "\n  " + entry + "\n"] where rest.hasPrefix(insertion) {
            return String(text[..<afterBrace]) + rest.dropFirst(insertion.count)
        }
        return nil
    }

    static func isOurs(_ data: Data, command: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let statusLine = object["statusLine"] as? [String: Any] else { return false }
        return statusLine["type"] as? String == "command" && statusLine["command"] as? String == command
    }

    static func isValidWithoutStatusLine(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["statusLine"] == nil
    }

    // MARK: - Files

    static func writeScript(configDirectory: URL, script: URL) throws {
        guard let data = try? Data(contentsOf: script), !data.isEmpty else { throw SetupError.scriptMissing }
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try writeAtomically(data, to: configDirectory.appendingPathComponent(scriptName), permissions: 0o755)
    }

    /// Writes beside the target with its final permissions, then renames over it.
    static func writeAtomically(_ data: Data, to url: URL, permissions: Int) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                             attributes: [.posixPermissions: permissions]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        guard rename(temporary.path, url.path) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    // MARK: - Commands

    static func expand(_ word: String, home: String) -> String {
        var path = word
        for prefix in ["~/", "$HOME/", "${HOME}/"] where path.hasPrefix(prefix) {
            path = home + "/" + path.dropFirst(prefix.count)
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Splits a command on spaces, honouring single and double quotes. Enough to find a script path.
    static func shellWords(_ command: String) -> [String] {
        var words: [String] = [], current = "", quote: Character?, started = false
        for character in command.trimmingCharacters(in: .whitespacesAndNewlines) {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character; started = true
            } else if character.isWhitespace {
                if started { words.append(current); current = ""; started = false }
            } else {
                current.append(character); started = true
            }
        }
        if started { words.append(current) }
        return words
    }
}
