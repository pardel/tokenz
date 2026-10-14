import AppKit
import SwiftUI
import UsageCore

enum Theme {
    static let claude = Color(nsColor: .systemOrange)
    static let codex = Color(nsColor: .systemBlue)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let text = Color.primary
    static let muted = Color.secondary
    static let warning = Color(nsColor: .systemRed)
    static let body = Font.system(size: 12)
    static let label = Font.system(size: 11)
    static let title = Font.system(size: 17, weight: .semibold)
    static let number = Font.system(size: 30, weight: .semibold, design: .rounded)
    static func accent(_ provider: Provider) -> Color { provider == .claude ? claude : codex }
}

struct PanelView: View {
    @ObservedObject var model: AppModel
    private var panelHeight: CGFloat {
        min(700, max(360, (NSScreen.main?.visibleFrame.height ?? 900) - 80))
    }
    /// Other Macs, when their folder holds anything to show or to warn about.
    private var others: OtherMacs? { model.snapshot?.otherMacs.flatMap { $0.isEmpty ? nil : $0 } }
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Tokenz").font(Theme.title)
                    Text(model.settingsVisible ? "Preferences" : "Your tokens, at a glance.").foregroundStyle(Theme.muted)
                }
                Spacer()
                if model.refreshing && (model.snapshot != nil || model.settingsVisible) {
                    ProgressView().controlSize(.small).accessibilityLabel("Reading usage")
                }
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.refreshing).help("Refresh usage (⌘R)").keyboardShortcut("r")
                    .accessibilityLabel("Refresh usage")
                Button { model.settingsVisible.toggle() } label: {
                    Image(systemName: model.settingsVisible ? "chart.bar" : "gearshape")
                }.help(model.settingsVisible ? "Show usage" : "Settings")
                    .accessibilityLabel(model.settingsVisible ? "Show usage" : "Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .help("Quit Tokenz (⌘Q)").keyboardShortcut("q")
                    .accessibilityLabel("Quit Tokenz")
            }
            if model.settingsVisible { SettingsView(model: model) }
            else {
                Picker("Usage period", selection: $model.period) {
                    ForEach(UsagePeriod.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                if let snapshot = model.snapshot {
                    let now = Date()
                    let start = model.period.start(at: now)
                    let total = snapshot.providers.reduce(Int64(0)) { $0 + $1.tokens(since: start, until: now).total }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(TokenFormat.compact(total)).font(Theme.number).monospacedDigit()
                                .help("\(total.formatted()) tokens")
                            Text("tokens").foregroundStyle(Theme.muted)
                            Spacer()
                            Text(others == nil ? "LOCAL USAGE" : "THIS MAC")
                                .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.muted)
                        }
                        if let others, !others.machines.isEmpty {
                            let all = others.machines.reduce(total) { $0 + $1.tokens(since: start, until: now).total }
                            Text("\(TokenFormat.compact(all)) tokens on all Macs").foregroundStyle(Theme.muted)
                                .help("\(all.formatted()) tokens: this Mac and \(others.machines.map(\.name).joined(separator: ", "))")
                        }
                    }
                    ActivityView(providers: snapshot.providers, period: model.period, now: now)
                    ForEach(snapshot.providers, id: \.provider) { usage in
                        ProviderView(usage: usage, start: start, now: now, feedExists: model.claudeFeedExists,
                                     onSetUp: { model.settingsVisible = true })
                    }
                    if let others { OtherMacsView(others: others, start: start, now: now) }
                    HStack {
                        Text("Updated \(snapshot.refreshedAt.formatted(date: .omitted, time: .shortened)) · every 5 min")
                            .font(Theme.label).foregroundStyle(Theme.muted)
                        Spacer()
                        Button("Export…") { model.exportCSV() }.font(Theme.label).help("Export daily totals as CSV")
                    }
                } else {
                    VStack(spacing: 12) {
                        ProgressView().progressViewStyle(.circular).controlSize(.large)
                            .frame(width: 36, height: 36)
                            .accessibilityLabel("Loading token usage")
                        Text("Reading local sessions…").font(.headline)
                        Text("The first scan can take a moment.")
                            .foregroundStyle(Theme.muted)
                    }.multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .frame(height: max(160, panelHeight - 200))
                }
                Text(others == nil ? "Tokens recorded on this Mac. Cached input is included. Subscription allowances are separate."
                     : "Tokens recorded on this Mac; other Macs' saved daily totals are in their own card. Cached input is included. Subscription allowances are separate.")
                    .font(Theme.label).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            if let message = model.message {
                Label(message, systemImage: "exclamationmark.triangle").font(Theme.label).foregroundStyle(Theme.warning)
            }
        }
        .font(Theme.body).padding(20).frame(width: 390)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 390, height: panelHeight)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct ProviderView: View {
    let usage: ProviderUsage
    let start: Date
    let now: Date
    var feedExists = true
    var onSetUp: (() -> Void)?
    var body: some View {
        let tokens = usage.tokens(since: start, until: now)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: usage.provider == .claude ? "sparkle" : "circle.hexagongrid")
                    .foregroundStyle(Theme.accent(usage.provider))
                Text(usage.provider.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(usage.issue != nil && usage.files == 0 ? "—" : TokenFormat.compact(tokens.total))
                    .font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
                    .help("\(tokens.total.formatted()) tokens")
            }
            if let issue = usage.issue {
                Label(issue, systemImage: "exclamationmark.triangle").font(Theme.label)
                    .foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            if usage.files > 0 {
                HStack(spacing: 0) {
                    stat("Input", tokens.input)
                    stat("Output", tokens.output)
                    stat("Cache read", tokens.cached)
                    if tokens.cacheWrite > 0 { stat("Cache write", tokens.cacheWrite) }
                }
                let sessions = usage.sessions(since: start)
                Text("\(sessions) session\(sessions == 1 ? "" : "s") · \(tokens.total == 0 ? "No usage in this period" : "Input includes cache")")
                    .font(Theme.label).foregroundStyle(Theme.muted)
            }
            Group {
                if let quota = usage.quota {
                    Divider()
                    ForEach(quota.windows) { window in
                        QuotaView(window: window, provider: usage.provider, now: now)
                    }
                    Text("Last reported \(quota.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 10)).foregroundStyle(Theme.muted)
                } else if usage.provider == .codex {
                    Text("Plan limit appears after Codex reports usage.")
                        .font(Theme.label).foregroundStyle(Theme.muted)
                } else if feedExists {
                    Text("Waiting for Claude Code's next response. Plan percentages come on Pro and Max plans.")
                        .font(Theme.label).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack {
                        Text("Claude percentages need a one-time status-line step.")
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if let onSetUp { Button("Set up…", action: onSetUp).help("Open Settings to set up Claude's status line") }
                    }.font(Theme.label).foregroundStyle(Theme.muted)
                }
            }
        }.padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
    }
    private func stat(_ label: String, _ value: Int64) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10)).foregroundStyle(Theme.muted)
            Text(TokenFormat.compact(value)).monospacedDigit().help(value.formatted())
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Other Macs' saved daily totals, each with the time its file last changed.
struct OtherMacsView: View {
    let others: OtherMacs
    let start: Date
    let now: Date
    var body: some View {
        let total = others.machines.reduce(Tokens()) { $0 + $1.tokens(since: start, until: now) }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "desktopcomputer").foregroundStyle(Theme.muted)
                Text("Other Macs").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(others.machines.isEmpty ? "—" : TokenFormat.compact(total.total))
                    .font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
                    .help("\(total.total.formatted()) tokens")
            }
            ForEach(others.machines, id: \.name) { machine in
                let tokens = machine.tokens(since: start, until: now)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(machine.name).font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text(TokenFormat.compact(tokens.total)).monospacedDigit().help("\(tokens.total.formatted()) tokens")
                    }
                    Text(detail(machine)).font(Theme.label).foregroundStyle(Theme.muted)
                }
            }
            ForEach(others.issues, id: \.self) { issue in
                Label(issue, systemImage: "exclamationmark.triangle").font(Theme.label)
                    .foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
    }
    private func detail(_ machine: MachineUsage) -> String {
        let sameDay = Calendar.current.isDate(machine.asOf, inSameDayAs: now)
        let asOf = machine.asOf.formatted(date: sameDay ? .omitted : .abbreviated, time: .shortened)
        let providers = Provider.allCases.map { provider in
            "\(provider == .claude ? "Claude" : "Codex") \(TokenFormat.compact(machine.tokens(provider, since: start, until: now).total))"
        }
        return (["As of \(asOf)"] + providers).joined(separator: " · ")
    }
}

struct QuotaView: View {
    let window: QuotaWindow
    let provider: Provider
    let now: Date
    var body: some View {
        let expired = window.isExpired(at: now)
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(window.label)
                Spacer()
                Text(expired ? "Awaiting update" : "\(Int(window.usedPercent.rounded()))% used")
                    .foregroundStyle(!expired && window.usedPercent >= 90 ? Theme.warning : Theme.muted)
            }.font(Theme.label)
            if !expired {
                ProgressView(value: window.usedPercent, total: 100)
                    .tint(window.usedPercent >= 90 ? Theme.warning : Theme.codex)
                    .accessibilityLabel(window.label).accessibilityValue("\(Int(window.usedPercent)) percent used")
            }
            if let reset = window.resetsAt {
                Text(expired ? "Reset time passed; \(provider == .codex ? "open Codex" : "use Claude Code") to update." : "Resets \(reset.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted)
            }
        }
    }
}

struct ActivityView: View {
    let providers: [ProviderUsage]
    let period: UsagePeriod
    let now: Date
    private var spacing: CGFloat { period == .week ? 14 : 2 }
    var body: some View {
        let buckets = UsageActivity.buckets(providers: providers, period: period, now: now)
        let maximum = max(1, buckets.map(\.total).max() ?? 1)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(period == .today ? "Today · hourly" : period == .week ? "Last 7 days" : "Last 30 days")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                ForEach(Provider.allCases) { provider in
                    HStack(spacing: 4) {
                        Circle().fill(Theme.accent(provider)).frame(width: 5, height: 5)
                        Text(provider == .claude ? "Claude" : "Codex").font(.system(size: 10)).foregroundStyle(Theme.muted)
                    }
                }
            }
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(buckets) { bucket in
                    VStack(spacing: 0) {
                        ForEach(Provider.allCases) { provider in
                            let amount = bucket.amounts[provider]?.total ?? 0
                            Rectangle().fill(Theme.accent(provider))
                                .frame(height: amount > 0 ? max(1, 46 * Double(amount) / Double(maximum)) : 0)
                        }
                    }.frame(maxWidth: .infinity).frame(height: 48, alignment: .bottom)
                        .background(Theme.surface.opacity(bucket.start > now ? 0.4 : 1), in: RoundedRectangle(cornerRadius: 3))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .contentShape(Rectangle())
                        .help(detail(bucket))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(detail(bucket))
                }
            }
            GeometryReader { geometry in
                let width = (geometry.size.width - spacing * CGFloat(buckets.count - 1)) / CGFloat(buckets.count)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(buckets.enumerated()), id: \.element.id) { index, bucket in
                        if let label = axisLabel(bucket, index: index, count: buckets.count) {
                            Text(label).font(.system(size: 10)).foregroundStyle(Theme.muted)
                                .position(x: max(12, min(geometry.size.width - 12, CGFloat(index) * (width + spacing) + width / 2)), y: 6)
                        }
                    }
                }
            }.frame(height: 12).accessibilityHidden(true)
        }
    }
    private func axisLabel(_ bucket: ActivityBucket, index: Int, count: Int) -> String? {
        switch period {
        case .today:
            let hour = Calendar.current.component(.hour, from: bucket.start)
            return hour % 6 == 0 ? String(format: "%02d", hour) : nil
        case .week: return bucket.start.formatted(.dateTime.weekday(.narrow))
        case .thirtyDays:
            return index == 0 || index == count - 1 || (index % 7 == 0 && index < count - 3)
                ? bucket.start.formatted(.dateTime.day()) : nil
        }
    }
    private func detail(_ bucket: ActivityBucket) -> String {
        let date = bucket.start.formatted(date: .abbreviated, time: .omitted)
        let label = period == .today
            ? "\(date), \(bucket.start.formatted(.dateTime.hour().minute()))–\(bucket.end.formatted(.dateTime.hour().minute()))"
            : date
        let amounts = Provider.allCases.map { "\($0.title): \((bucket.amounts[$0]?.total ?? 0).formatted())" }.joined(separator: " · ")
        return "\(label) · \(bucket.total.formatted()) tokens\n\(amounts)"
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("Show plan usage in menu bar", isOn: $model.showMenuPercentages)
            Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            Divider()
            Text("Session folders").font(.system(size: 13, weight: .semibold))
            ForEach(Provider.allCases) { provider in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(provider.title).font(.system(size: 12, weight: .medium))
                        Spacer()
                        Button("Choose…") { model.chooseFolder(for: provider) }
                    }
                    Text(model.paths[provider] ?? "").font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.muted).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Other Macs").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button("Choose…") { model.chooseOtherMacsFolder() }
                }
                Text(model.otherMacsPath).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.muted).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Tokenz adds the daily totals in each CSV file here, one per Mac and named after it, in the format Export… writes. A file named after this Mac is skipped.")
                    .font(Theme.label).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Button("Restore default folders") { model.restoreFolders() }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Claude percentage feed").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button("Choose…") { model.chooseQuotaFile() }
                }
                Text(model.claudeQuotaPath).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.muted).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            statusLineSection
            Divider()
            Text("About the counters").font(.system(size: 13, weight: .semibold))
            Text("Token usage comes from local session logs, including agent sessions. Today uses your Mac’s timezone; 7 and 30 days include today and the previous 6 or 29 days. Other Macs add the days saved in their files, as of each file’s last change; the chart shows this Mac only.")
            Text("Input includes cached tokens. Claude cache writes are included in input. Codex reasoning tokens are already included in output.")
            Text("The menu bar shows a 5-hour percentage beside each provider symbol and a weekly usage underline below. The percentage is hidden when unavailable, expired, or rounded to zero. Each is green below 70%, orange from 70% to under 90%, and red at 90% or above. Each symbol follows the weekly underline colour and remains neutral when weekly usage is unavailable. A dotted underline means no current weekly reading. Hover for exact values and reset times. A provider appears when its desktop app is installed or its session logs or plan feed exist. Codex reports limits in its logs; Claude reports them through its status line.")
            HStack {
                Link("Claude plan usage ↗", destination: URL(string: "https://claude.ai/settings/usage")!)
                Spacer()
                Link("Codex plan usage ↗", destination: URL(string: "https://chatgpt.com/codex/settings/usage")!)
            }.font(Theme.label)
            Text("No API keys. No uploads. Tokenz keeps only usage numbers in memory. Apart from a CSV you export, it writes nothing unless you ask it to set up the status line, and then only its script and Claude's settings.json, which it backs up first.")
                .font(Theme.label).foregroundStyle(Theme.muted)
        }.fixedSize(horizontal: false, vertical: true)
        .onAppear { model.refreshStatusLineState() }
    }

    /// Claude Code reports plan limits only to a status line command.
    @ViewBuilder private var statusLineSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Claude status line").font(.system(size: 12, weight: .medium))
            switch model.statusLineState {
            case .available:
                HStack(alignment: .firstTextBaseline) {
                    Text("Claude Code reports plan percentages only to a status line. Tokenz can add one that saves just the percentages and reset times.")
                        .foregroundStyle(Theme.muted)
                    Spacer()
                    Button("Set up…") { model.setUpStatusLine() }.disabled(!model.statusLineScriptAvailable)
                }
            case .installed:
                HStack {
                    Text("Set up by Tokenz.").foregroundStyle(Theme.muted)
                    Spacer()
                    Button("Remove…") { model.removeStatusLine() }
                }
            case .chained:
                Text("Your status line passes its input to Tokenz.").foregroundStyle(Theme.muted)
            case .existing:
                Text("You already have a status line. Add this line to its script, after the script reads its input with input=$(cat):")
                    .foregroundStyle(Theme.muted)
                Text(model.statusLineChainLine).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                HStack {
                    Button("Copy line") { model.copyStatusLineChainLine() }
                    Spacer()
                    Button("Install script only…") { model.installStatusLineScriptOnly() }
                        .disabled(!model.statusLineScriptAvailable)
                }
            case .unreadable:
                Text("settings.json could not be read, so Tokenz won't change it.").foregroundStyle(Theme.muted)
            }
            if let note = model.statusLineNote {
                Text(note).font(Theme.label).foregroundStyle(Theme.muted)
            }
        }.font(Theme.label).fixedSize(horizontal: false, vertical: true)
    }
}
