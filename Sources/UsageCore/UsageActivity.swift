import Foundation

public struct ActivityBucket: Identifiable, Sendable {
    public let start: Date
    public let end: Date
    public var amounts: [Provider: Tokens]
    public var id: Date { start }
    public var total: Int64 { amounts.values.reduce(0) { $0 + $1.total } }
}

public enum UsageActivity {
    /// Calendar hours for Today (including 23/25-hour DST days), calendar days
    /// for rolling periods. Future slots stay empty; totals stop at `now`.
    public static func buckets(providers: [ProviderUsage], period: UsagePeriod,
                               now: Date, calendar: Calendar = .current) -> [ActivityBucket] {
        let start = period.start(at: now, calendar: calendar)
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let component: Calendar.Component = period == .today ? .hour : .day
        var result: [ActivityBucket] = []
        var cursor = start
        while cursor < end {
            let next = calendar.date(byAdding: component, value: 1, to: cursor)!
            result.append(ActivityBucket(start: cursor, end: next, amounts: [:]))
            cursor = next
        }
        let indices = Dictionary(uniqueKeysWithValues: result.enumerated().map { ($0.element.start, $0.offset) })
        for provider in providers {
            for record in provider.records where record.date >= start && record.date < now {
                let slot = period == .today
                    ? calendar.dateInterval(of: .hour, for: record.date)!.start
                    : calendar.startOfDay(for: record.date)
                if let index = indices[slot] {
                    result[index].amounts[provider.provider] = (result[index].amounts[provider.provider] ?? Tokens()) + record.tokens
                }
            }
        }
        return result
    }
}
