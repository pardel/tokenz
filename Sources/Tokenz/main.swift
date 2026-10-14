import AppKit
import SwiftUI
import UsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let model = AppModel()
    var item: NSStatusItem!
    let popover = NSPopover()
    var previewWindow: NSWindow?
    let menuBarLabel = MenuBarLabel()
    let appearanceObserver = MenuBarAppearanceObserver(frame: .zero)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "Tokenz token usage")
        item.button?.imagePosition = .imageOnly
        item.button?.imageScaling = .scaleNone
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        appearanceObserver.onChange = { [weak self] in self?.updateStatus() }
        item.button?.addSubview(appearanceObserver)
        popover.behavior = .transient
        popover.delegate = self
        let controller = NSHostingController(rootView: PanelView(model: model))
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        model.onUpdate = { [weak self] in self?.updateStatus() }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.updateStatus() }
            }
        }
        model.start()
        updateStatus()
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.togglePopover() }
        }
        if CommandLine.arguments.contains("--preview") {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 640),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Tokenz preview"
            window.contentViewController = NSHostingController(rootView: PanelView(model: model))
            window.center(); window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            previewWindow = window
        }
    }
    func updateStatus() {
        guard let button = item.button else { return }
        let now = Date()
        let providers = visibleProviders()
        if model.showMenuPercentages {
            func quota(_ provider: Provider) -> QuotaSnapshot? {
                model.snapshot?.providers.first(where: { $0.provider == provider })?.quota
            }
            button.image = menuBarLabel.image(claudeQuota: quota(.claude), codexQuota: quota(.codex),
                                             now: now, appearance: button.effectiveAppearance,
                                             highlighted: popover.isShown, visibleProviders: providers)
        } else {
            button.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "Tokenz token usage")
        }
        button.title = ""
        let descriptions = Provider.allCases.filter { providers.contains($0) }.map { provider -> String in
            let quota = model.snapshot?.providers.first(where: { $0.provider == provider })?.quota
            let windows = [(300, "5-hour (number)"), (10080, "Weekly (underline)")].map { minutes, label in
                guard let window = quota?.activeWindow(minutes: minutes, at: now) else {
                    return "\(label): unavailable"
                }
                let reset = window.resetsAt.map { " · resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
                return "\(label): \(Int(window.usedPercent.rounded()))% used\(reset)"
            }
            let reported = quota.map { "\nReported \($0.date.formatted(date: .abbreviated, time: .shortened))" } ?? ""
            return "\(provider.title)\n\(windows.joined(separator: "\n"))\(reported)"
        }
        let availability = providers.isEmpty ? ["No Claude or Codex app, session logs or plan feed found."] : []
        button.toolTip = (["Tokenz"] + descriptions + availability).joined(separator: "\n")
        button.setAccessibilityLabel((["Tokenz"] + descriptions + availability + ["Click to view token usage."]).joined(separator: ". "))
    }
    /// A provider shows when its desktop app is installed, or when its session logs or plan feed exist,
    /// so CLI-only users get a reading too.
    func visibleProviders() -> Set<Provider> {
        let found = model.snapshot?.providers.filter { $0.files > 0 || $0.quota != nil }.map(\.provider) ?? []
        return ProviderApps.installedProviders().union(found)
    }
    @objc func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            model.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
        button.isHighlighted = popover.isShown
        updateStatus()
    }
    func popoverDidClose(_ notification: Notification) {
        item.button?.isHighlighted = false
        updateStatus()
    }
}

if CommandLine.arguments.contains("--diagnose") {
    // Same folders and feed as the app, including choices saved in Settings.
    let snapshot = UsageScanner().scan(paths: Preferences.paths, claudeQuotaPath: Preferences.claudeQuotaPath,
                                       otherMacsPath: Preferences.otherMacsPath,
                                       thisMac: Set([Preferences.thisMac].compactMap { $0 }))
    let today = Calendar.current.startOfDay(for: Date())
    for usage in snapshot.providers {
        let tokens = usage.tokens(since: today)
        print("\(usage.provider.title): \(usage.files) files, \(usage.records.count) usage records; today \(tokens.total) tokens (input \(tokens.input), output \(tokens.output), cached \(tokens.cached), cache write \(tokens.cacheWrite))")
        if let issue = usage.issue { print("  \(issue)") }
        if let quota = usage.quota {
            for window in quota.windows { print("  \(window.label): \(window.usedPercent)% used, recorded \(quota.date)") }
        }
    }
    if let others = snapshot.otherMacs {
        print("Other Macs: \(others.path)")
        for machine in others.machines {
            let tokens = machine.tokens(since: today, until: Date())
            print("  \(machine.name), as of \(machine.asOf): today \(tokens.total) tokens (input \(tokens.input), output \(tokens.output), cached \(tokens.cached), cache write \(tokens.cacheWrite))")
        }
        for issue in others.issues { print("  \(issue)") }
    }
} else {
    MainActor.assumeIsolated {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
