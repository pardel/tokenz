import AppKit
import UsageCore

/// Provider symbols with a 5-hour percentage and a weekly underline.
@MainActor
final class MenuBarLabel {
    private let claude: NSImage
    private let codex: NSImage
    private let appIcon: NSImage

    /// Generic SF Symbols stand for the providers: Tokenz ships no third-party marks.
    init(appIcon: NSImage? = nil) {
        claude = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Claude")!
        codex = NSImage(systemSymbolName: "circle.hexagongrid", accessibilityDescription: "Codex")!
        self.appIcon = appIcon
            ?? Bundle.main.resourceURL.flatMap { NSImage(contentsOf: $0.appendingPathComponent("AppIcon.icns")) }
            ?? NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "Tokenz")!
    }

    func image(claudeQuota: QuotaSnapshot?, codexQuota: QuotaSnapshot?, now: Date,
               appearance: NSAppearance, highlighted: Bool = false,
               visibleProviders: Set<Provider> = Set(Provider.allCases)) -> NSImage {
        let providers = Provider.allCases.filter { visibleProviders.contains($0) }
        if providers.isEmpty {
            let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
                self.appIcon.draw(in: rect)
                return true
            }
            image.isTemplate = false
            return image
        }
        func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
            NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
        }
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let ink = dark ? rgb(27, 38, 38) : rgb(245, 247, 247)
        let track = dark ? rgb(145, 162, 162) : rgb(129, 139, 139)
        let green = dark ? rgb(0, 105, 62) : rgb(94, 226, 148)
        let orange = dark ? rgb(143, 79, 0) : rgb(255, 176, 82)
        let red = dark ? rgb(182, 38, 54) : rgb(255, 135, 144)
        func usageColor(_ percent: Double) -> NSColor {
            percent >= 90 ? red : percent >= 70 ? orange : green
        }
        var background = dark ? rgb(216, 224, 224) : rgb(59, 65, 65)
        if highlighted {
            background = background.blended(withFraction: 0.05, of: dark ? .white : .black)!
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        let entries = providers.map { provider in
            let quota = provider == .claude ? claudeQuota : codexQuota
            let short = quota?.activeWindow(minutes: 300, at: now)
            let weekly = quota?.activeWindow(minutes: 10080, at: now)
            let percent = short.map { Int(min(100, max(0, $0.usedPercent)).rounded()) }
            // Preserve the compact zero state; an absent short window never borrows weekly usage.
            let number: NSAttributedString? = percent.flatMap { value in
                guard value > 0, let short else { return nil }
                return NSAttributedString(string: "\(value)%", attributes: [
                    .font: font, .foregroundColor: usageColor(short.usedPercent)
                ])
            }
            let width: CGFloat = 14 + (number.map { 3 + ceil($0.size().width) } ?? 0)
            return (provider: provider, weekly: weekly, number: number, width: width)
        }
        let size = NSSize(width: 6 + entries.reduce(0) { $0 + $1.width }
                          + CGFloat(entries.count - 1) * 8, height: 22)
        let image = NSImage(size: size, flipped: true) { _ in
            background.setFill()
            NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 2, yRadius: 2).fill()
            var offset: CGFloat = 3
            for entry in entries {
                let symbolColor = entry.weekly.map { usageColor($0.usedPercent) } ?? ink
                let source = entry.provider == .claude ? self.claude : self.codex
                let symbolSize: CGFloat = entry.provider == .claude ? 14 : 13
                let symbolRect = NSRect(x: offset + (14 - symbolSize) / 2,
                                      y: 8.25 - symbolSize / 2,
                                      width: symbolSize, height: symbolSize)
                let symbol = NSImage(size: symbolRect.size, flipped: false) { rect in
                    symbolColor.setFill(); rect.fill()
                    source.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
                    return true
                }
                symbol.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1,
                          respectFlipped: true, hints: nil)
                if let number = entry.number {
                    number.draw(at: NSPoint(x: offset + 17, y: 8.25 - number.size().height / 2))
                }
                let rect = NSRect(x: offset, y: 17, width: entry.width, height: 2.5)
                track.withAlphaComponent(0.35).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 0.5, yRadius: 0.5).fill()
                if let window = entry.weekly {
                    let percent = min(100, max(0, window.usedPercent))
                    if percent > 0 {
                        usageColor(percent).setFill()
                        let fill = NSRect(x: rect.minX, y: rect.minY,
                                          width: rect.width * CGFloat(percent / 100), height: rect.height)
                        NSBezierPath(roundedRect: fill, xRadius: 0.5, yRadius: 0.5).fill()
                    }
                } else {
                    let missing = NSBezierPath()
                    missing.move(to: NSPoint(x: rect.minX + 1, y: rect.midY))
                    missing.line(to: NSPoint(x: rect.maxX - 1, y: rect.midY))
                    missing.lineWidth = 1; missing.lineCapStyle = .round
                    missing.setLineDash([1, 2], count: 2, phase: 0)
                    track.setStroke(); missing.stroke()
                }
                offset += entry.width + 8
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// Resolve by bundle identity so renamed apps and user Applications folders work.
@MainActor
enum ProviderApps {
    static func installedProviders() -> Set<Provider> {
        let identifiers: [Provider: [String]] = [
            .claude: ["com.anthropic.claudefordesktop"],
            .codex: ["com.openai.codex", "com.openai.chat"]
        ]
        return Set(Provider.allCases.filter { provider in
            identifiers[provider, default: []].contains { identifier in
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier),
                      FileManager.default.fileExists(atPath: url.path) else { return false }
                return Bundle(url: url)?.bundleIdentifier == identifier
            }
        })
    }
}

/// The menu bar can change appearance independently from the rest of the app.
@MainActor
final class MenuBarAppearanceObserver: NSView {
    var onChange: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onChange?()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
