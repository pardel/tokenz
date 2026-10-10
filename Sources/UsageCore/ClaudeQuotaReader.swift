import Foundation

/// Reads the documented rate_limits payload supplied to Claude Code status lines.
/// Only percentages and reset dates leave the reader; the rest of the JSON is discarded.
public enum ClaudeQuotaReader {
    public static func read(from path: String) -> QuotaSnapshot? {
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        guard let attributes = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              (attributes.fileSize ?? Int.max) <= 1_048_576,
              let data = try? Data(contentsOf: url),
              let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = row["rate_limits"] as? [String: Any] else { return nil }
        return parse(limits, reportedAt: attributes.contentModificationDate ?? .distantPast)
    }

    static func parse(_ limits: [String: Any], reportedAt: Date) -> QuotaSnapshot? {
        let windows = [("five_hour", 300), ("seven_day", 10080)].compactMap { key, minutes -> QuotaWindow? in
            guard let window = limits[key] as? [String: Any],
                  let percentage = window["used_percentage"] as? NSNumber,
                  percentage.doubleValue.isFinite else { return nil }
            let reset = (window["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return QuotaWindow(id: key, usedPercent: max(0, min(100, percentage.doubleValue)),
                               minutes: minutes, resetsAt: reset)
        }
        guard !windows.isEmpty else { return nil }
        return QuotaSnapshot(date: reportedAt, windows: windows)
    }
}
