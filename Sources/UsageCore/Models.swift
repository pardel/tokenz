import Foundation

public enum Provider: String, CaseIterable, Identifiable, Sendable {
    case claude, codex
    public var id: String { rawValue }
    public var title: String { self == .claude ? "Claude Code" : "Codex" }
}

public struct Tokens: Equatable, Sendable {
    // Input includes both cache reads and writes. Reasoning is part of output.
    public var input: Int64
    public var output: Int64
    public var cached: Int64
    public var cacheWrite: Int64
    public var total: Int64 { input + output }
    public var uncached: Int64 { max(0, input - cached - cacheWrite) }
    public init(input: Int64 = 0, output: Int64 = 0, cached: Int64 = 0, cacheWrite: Int64 = 0) {
        self.input = input; self.output = output; self.cached = cached; self.cacheWrite = cacheWrite
    }
    public static func + (lhs: Self, rhs: Self) -> Self {
        .init(input: lhs.input + rhs.input, output: lhs.output + rhs.output,
              cached: lhs.cached + rhs.cached, cacheWrite: lhs.cacheWrite + rhs.cacheWrite)
    }
    public func merged(with other: Self) -> Self {
        .init(input: max(input, other.input), output: max(output, other.output),
              cached: max(cached, other.cached), cacheWrite: max(cacheWrite, other.cacheWrite))
    }
}

public struct UsageRecord: Sendable {
    public var key: String
    public var date: Date
    public var tokens: Tokens
    public var session: String
}

public struct QuotaWindow: Identifiable, Sendable {
    public var id: String
    public var usedPercent: Double
    public var minutes: Int
    public var resetsAt: Date?
    public var label: String {
        if minutes == 10080 { return "Weekly limit" }
        if minutes == 300 { return "5-hour limit" }
        if minutes >= 1440 { return "\(minutes / 1440)-day limit" }
        if minutes >= 60 { return "\(minutes / 60)-hour limit" }
        return "\(minutes)-minute limit"
    }
    public func isExpired(at date: Date) -> Bool { resetsAt.map { $0 <= date } ?? false }
    /// False for a reading of a window that has ended while `held`'s has not, or one no higher than
    /// `held` for the same window: usage within a window only grows. Otherwise the newer report wins.
    public func supersedes(_ held: QuotaWindow, at now: Date) -> Bool {
        if isExpired(at: now) && !held.isExpired(at: now) { return false }
        if let resetsAt, resetsAt == held.resetsAt { return usedPercent > held.usedPercent }
        return true
    }
}

public struct QuotaSnapshot: Sendable {
    public var date: Date
    public var windows: [QuotaWindow]
    /// Never substitute another period: each menu bar indicator has one meaning.
    public func activeWindow(minutes: Int, at now: Date) -> QuotaWindow? {
        windows.first { $0.minutes == minutes && !$0.isExpired(at: now) }
    }
    /// Every Claude Code session writes the same feed with the limits from its own last response,
    /// so a session left idle can save older figures. Keeps each window the report does not
    /// supersede; the date moves only when a window changes.
    public func merging(_ report: QuotaSnapshot, at now: Date) -> QuotaSnapshot {
        var merged = self
        for window in report.windows {
            if let index = merged.windows.firstIndex(where: { $0.id == window.id }) {
                guard window.supersedes(merged.windows[index], at: now) else { continue }
                merged.windows[index] = window
            } else {
                merged.windows.append(window)
            }
            merged.date = max(merged.date, report.date)
        }
        return merged
    }
}

public struct ProviderUsage: Sendable {
    public var provider: Provider
    public var records: [UsageRecord] = []
    public var quota: QuotaSnapshot?
    public var files: Int = 0
    public var issue: String?
    public var path: String
    public init(provider: Provider, path: String) { self.provider = provider; self.path = path }
    public func tokens(since start: Date, until end: Date = .distantFuture) -> Tokens {
        records.filter { $0.date >= start && $0.date < end }.reduce(Tokens()) { $0 + $1.tokens }
    }
    public func sessions(since start: Date) -> Int {
        Set(records.filter { $0.date >= start }.map(\.session)).count
    }
    public var lastActivity: Date? { records.map(\.date).max() }
}

public struct UsageSnapshot: Sendable {
    public var providers: [ProviderUsage]
    public var refreshedAt: Date
    /// Other Macs' saved daily totals; nil when the scan was given no folder.
    public var otherMacs: OtherMacs?
    public init(providers: [ProviderUsage], refreshedAt: Date, otherMacs: OtherMacs? = nil) {
        self.providers = providers; self.refreshedAt = refreshedAt; self.otherMacs = otherMacs
    }
}

public enum UsagePeriod: String, CaseIterable, Identifiable {
    case today = "Today", week = "7 days", thirtyDays = "Last 30 days"
    public var id: String { rawValue }
    public func start(at now: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: now)
        switch self {
        case .today: return day
        case .week: return calendar.date(byAdding: .day, value: -6, to: day)!
        case .thirtyDays: return calendar.date(byAdding: .day, value: -29, to: day)!
        }
    }
}

public enum TokenFormat {
    public static func compact(_ n: Int64) -> String {
        let value = Double(n)
        if n >= 1_000_000_000 { return String(format: "%.1fB", value / 1_000_000_000) }
        if n >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", value / 1_000) }
        return String(n)
    }
}
