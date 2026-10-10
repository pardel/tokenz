import AppKit
import Combine
import ServiceManagement
import UniformTypeIdentifiers
import UsageCore

/// Saved folder and feed choices, with their defaults.
enum Preferences {
    static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    static var defaultPaths: [Provider: String] {
        [.claude: "\(home)/.claude/projects", .codex: "\(home)/.codex/sessions"]
    }
    /// Written by `scripts/tokenz-statusline.sh`: rate limits only, private to the user.
    static var defaultClaudeQuotaPath: String { "\(home)/.claude/tokenz-rate-limits.json" }
    static var paths: [Provider: String] {
        let defaults = UserDefaults.standard
        return [.claude: defaults.string(forKey: "claudePath") ?? defaultPaths[.claude]!,
                .codex: defaults.string(forKey: "codexPath") ?? defaultPaths[.codex]!]
    }
    static var claudeQuotaPath: String {
        UserDefaults.standard.string(forKey: "claudeQuotaPath") ?? defaultClaudeQuotaPath
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var snapshot: UsageSnapshot?
    @Published var refreshing = false
    @Published var period: UsagePeriod = .today
    @Published var settingsVisible = false
    @Published var message: String?
    @Published var showMenuPercentages: Bool {
        didSet { UserDefaults.standard.set(showMenuPercentages, forKey: "showMenuPercentages"); onUpdate?() }
    }
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @Published var paths: [Provider: String]
    @Published var claudeQuotaPath: String
    @Published var statusLineState: ClaudeStatusLineSetup.State = .available
    @Published var statusLineNote: String?
    /// The status-line script Tokenz offers to install, bundled by `scripts/build.sh`.
    /// `TOKENZ_STATUSLINE_SCRIPT` points a development run at `scripts/tokenz-statusline.sh`.
    static var statusLineScript: URL? = ProcessInfo.processInfo.environment["TOKENZ_STATUSLINE_SCRIPT"]
        .map { URL(fileURLWithPath: $0) } ?? Bundle.main.url(forResource: "tokenz-statusline", withExtension: "sh")
    var onUpdate: (() -> Void)?
    private let queue = DispatchQueue(label: "dev.pardel.tokenz.scanner", qos: .utility)
    private let scanner = UsageScanner()
    private var timer: Timer?
    private var feedTimer: Timer?
    private var feedModified: Date?

    init() {
        paths = Preferences.paths
        showMenuPercentages = UserDefaults.standard.object(forKey: "showMenuPercentages") as? Bool ?? true
        claudeQuotaPath = Preferences.claudeQuotaPath
        refreshStatusLineState()
    }
    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // The Claude feed is one small file that every status line rewrites; the logs wait for the full scan.
        feedTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshClaudeQuota() }
        }
        feedTimer?.tolerance = 5
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }
    /// Re-reads only the Claude feed, when it has changed since the last look.
    func refreshClaudeQuota() {
        let path = claudeQuotaPath
        let modified = (try? URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            .resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard !refreshing, snapshot != nil, modified != feedModified else { return }
        feedModified = modified
        queue.async { [scanner, weak self] in
            let quota = scanner.claudeQuota(path: path)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.claudeQuotaPath == path, var snapshot = self.snapshot,
                      let index = snapshot.providers.firstIndex(where: { $0.provider == .claude }) else { return }
                snapshot.providers[index].quota = quota
                self.snapshot = snapshot
                self.onUpdate?()
            }
        }
    }
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        refreshStatusLineState()
        let roots = paths
        let quotaPath = claudeQuotaPath
        queue.async { [scanner, weak self] in
            let result = scanner.scan(paths: roots, claudeQuotaPath: quotaPath)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.snapshot = result
                self.refreshing = false
                self.onUpdate?()
                if self.paths != roots || self.claudeQuotaPath != quotaPath { self.refresh() }
            }
        }
    }
    func chooseQuotaFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose Claude percentage JSON"
        panel.message = "Choose a JSON file saved by your Claude Code status line containing rate_limits. Tokenz reads only percentages and reset dates."
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.showsHiddenFiles = true
        panel.allowedContentTypes = [.json]
        panel.directoryURL = URL(fileURLWithPath: claudeQuotaPath).deletingLastPathComponent()
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            claudeQuotaPath = url.path
            UserDefaults.standard.set(url.path, forKey: "claudeQuotaPath")
            refresh()
        }
    }
    func chooseFolder(for provider: Provider) {
        let panel = NSOpenPanel()
        panel.title = "Choose \(provider.title) session folder"
        panel.message = provider == .claude ? "Select the projects folder inside your Claude configuration folder. Press ⌘⇧. to show hidden folders." : "Select the sessions folder inside your Codex configuration folder. Press ⌘⇧. to show hidden folders."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: paths[provider] ?? NSHomeDirectory())
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            paths[provider] = url.path
            UserDefaults.standard.set(url.path, forKey: "\(provider.rawValue)Path")
            refresh()
        }
    }
    func restoreFolders() {
        paths = Preferences.defaultPaths
        for provider in Provider.allCases { UserDefaults.standard.removeObject(forKey: "\(provider.rawValue)Path") }
        refresh()
    }
    // MARK: Claude status line

    var claudeConfigDirectory: URL {
        ClaudeStatusLineSetup.configDirectory(projectsPath: paths[.claude] ?? Preferences.defaultPaths[.claude]!)
    }
    var claudeFeedExists: Bool {
        FileManager.default.fileExists(atPath: NSString(string: claudeQuotaPath).expandingTildeInPath)
    }
    var statusLineScriptAvailable: Bool {
        Self.statusLineScript.map { FileManager.default.isReadableFile(atPath: $0.path) } ?? false
    }
    var statusLineChainLine: String { ClaudeStatusLineSetup.chainLine(configDirectory: claudeConfigDirectory) }
    func refreshStatusLineState() {
        let state = ClaudeStatusLineSetup.state(configDirectory: claudeConfigDirectory)
        guard state != statusLineState else { return }
        statusLineState = state
        statusLineNote = nil // A note describes the state it was written for.
    }
    private func tilde(_ url: URL) -> String { NSString(string: url.path).abbreviatingWithTildeInPath }
    private func confirm(_ title: String, _ text: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
    private func describe(_ error: Error) -> String {
        switch error as? ClaudeStatusLineSetup.SetupError {
        case .notAllowed?: return "Claude's settings changed since this screen opened. Nothing was changed."
        case .scriptMissing?: return "This build of Tokenz has no status-line script. Nothing was changed."
        case .invalidSettings?: return "settings.json would not have stayed valid, so it was left unchanged."
        case nil: return error.localizedDescription
        }
    }
    /// The script writes the default feed, so point Tokenz back at it.
    private func useDefaultFeed() {
        UserDefaults.standard.removeObject(forKey: "claudeQuotaPath")
        claudeQuotaPath = Preferences.defaultClaudeQuotaPath
    }
    func setUpStatusLine() {
        guard let script = Self.statusLineScript else { return }
        let directory = claudeConfigDirectory
        let settings = directory.appendingPathComponent("settings.json")
        let backup = FileManager.default.fileExists(atPath: settings.path)
            ? ", after saving a copy as \(ClaudeStatusLineSetup.backupName)" : ""
        guard confirm("Set up Claude's status line?",
                      "Tokenz will make two changes:\n\n• Add the script \(tilde(directory.appendingPathComponent(ClaudeStatusLineSetup.scriptName))).\n• Add a statusLine entry to \(tilde(settings))\(backup).\n\nThe script saves only plan percentages and reset times, readable by you alone.",
                      action: "Set Up") else { return }
        do {
            try ClaudeStatusLineSetup.install(configDirectory: directory, script: script)
            useDefaultFeed()
            message = nil
            refreshStatusLineState()
            statusLineNote = "Set up. Claude Code shows the status line from its next response, and Claude percentages follow after that."
        } catch { message = "Could not set up the status line: \(describe(error))" }
        refresh()
    }
    func installStatusLineScriptOnly() {
        guard let script = Self.statusLineScript else { return }
        let directory = claudeConfigDirectory
        guard confirm("Install the script only?",
                      "Tokenz will add the script \(tilde(directory.appendingPathComponent(ClaudeStatusLineSetup.scriptName))). Your status line and settings.json stay as they are; add the line shown to your status line script to start the feed.",
                      action: "Install Script") else { return }
        do {
            try ClaudeStatusLineSetup.installScriptOnly(configDirectory: directory, script: script)
            useDefaultFeed()
            message = nil
            refreshStatusLineState()
            statusLineNote = "Script installed. Add the line to your status line script; percentages follow Claude Code's next response."
        } catch { message = "Could not install the script: \(describe(error))" }
        refresh()
    }
    func removeStatusLine() {
        let directory = claudeConfigDirectory
        let kept = FileManager.default.fileExists(atPath: directory.appendingPathComponent(ClaudeStatusLineSetup.backupName).path)
            ? "The saved percentages and \(ClaudeStatusLineSetup.backupName) stay." : "The saved percentages stay."
        guard confirm("Remove Tokenz's status line?",
                      "Tokenz will remove its statusLine entry from \(tilde(directory.appendingPathComponent("settings.json"))) and delete \(ClaudeStatusLineSetup.scriptName). \(kept) Claude percentages stop updating.",
                      action: "Remove") else { return }
        do {
            try ClaudeStatusLineSetup.remove(configDirectory: directory)
            message = nil
            refreshStatusLineState()
            statusLineNote = "Removed. Claude Code no longer runs Tokenz's status line."
        } catch { message = "Could not remove the status line: \(describe(error))" }
        refresh()
    }
    func copyStatusLineChainLine() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(statusLineChainLine, forType: .string)
        statusLineNote = "Line copied."
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval {
                message = "Allow Tokenz in System Settings → General → Login Items."
                SMAppService.openSystemSettingsLoginItems()
            } else { message = nil }
        } catch { message = "Could not update login settings: \(error.localizedDescription)" }
    }
    func exportCSV() {
        guard let snapshot else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "tokenz-usage.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let calendar = Calendar.current
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        var lines = ["date,provider,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,total_tokens"]
        for provider in snapshot.providers {
            let days = Dictionary(grouping: provider.records) { calendar.startOfDay(for: $0.date) }
            for day in days.keys.sorted() {
                let tokens = days[day]!.reduce(Tokens()) { $0 + $1.tokens }
                lines.append("\(formatter.string(from: day)),\(provider.provider.rawValue),\(tokens.input),\(tokens.output),\(tokens.cached),\(tokens.cacheWrite),\(tokens.total)")
            }
        }
        do { try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8) }
        catch { message = "Could not save CSV: \(error.localizedDescription)" }
    }
}
