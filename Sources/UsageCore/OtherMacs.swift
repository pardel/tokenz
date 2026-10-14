import Foundation

/// Tokenz's CSV of daily totals: what Export… writes, and what the Other Macs folder holds, one
/// file per Mac. A day is a calendar day where it was written, as yyyy-MM-dd.
public enum UsageCSV {
    public static let header = "date,provider,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,total_tokens"

    public enum ParseError: Error, Equatable {
        case header
        /// The first line that is not a day's totals, counting the header as line 1.
        case line(Int)
    }

    /// Each provider's records as daily totals, one line per day and provider with usage.
    public static func export(_ providers: [ProviderUsage], calendar: Calendar = .current) -> String {
        var lines = [header]
        for usage in providers {
            let days = Dictionary(grouping: usage.records) { calendar.startOfDay(for: $0.date) }
            for day in days.keys.sorted() {
                let tokens = days[day]!.reduce(Tokens()) { $0 + $1.tokens }
                lines.append([Self.day(day, timeZone: calendar.timeZone), usage.provider.rawValue,
                              "\(tokens.input)", "\(tokens.output)", "\(tokens.cached)", "\(tokens.cacheWrite)",
                              "\(tokens.total)"].joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A date's calendar day: Gregorian, in Western digits, whatever the Mac's calendar and locale.
    public static func day(_ date: Date, timeZone: TimeZone = .current) -> String {
        dayFormatter(timeZone).string(from: date)
    }

    /// A whole file or nothing: a line that is not a day's totals throws rather than being skipped,
    /// so a damaged file is never counted in part. Rows for tools Tokenz does not show are skipped.
    public static func parse(_ text: String) throws -> [String: [Provider: Tokens]] {
        var lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        if lines.last == "" { lines.removeLast() }
        guard lines.first == header else { throw ParseError.header }
        let formatter = dayFormatter(TimeZone(identifier: "UTC")!)
        func isDay(_ field: String) -> Bool {
            field.count == 10 && formatter.date(from: field).map { formatter.string(from: $0) == field } == true
        }
        var days: [String: [Provider: Tokens]] = [:]
        var seen = Set<String>()
        for (index, line) in lines.enumerated().dropFirst() {
            let fields = line.components(separatedBy: ",")
            // No day comes near a quadrillion tokens; the cap keeps every sum from overflowing.
            let numbers = fields.dropFirst(2).compactMap { Int64($0) }.filter { (0...1_000_000_000_000_000).contains($0) }
            guard fields.count == 7, isDay(fields[0]), !fields[1].isEmpty, numbers.count == 5,
                  numbers[0] + numbers[1] == numbers[4], seen.insert(fields[0] + "," + fields[1]).inserted
            else { throw ParseError.line(index + 1) }
            guard let provider = Provider(rawValue: fields[1]) else { continue }
            days[fields[0], default: [:]][provider] = Tokens(input: numbers[0], output: numbers[1],
                                                             cached: numbers[2], cacheWrite: numbers[3])
        }
        return days
    }

    private static func dayFormatter(_ timeZone: TimeZone) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = timeZone
        return formatter
    }
}

/// Another Mac's daily totals, from its file in the Other Macs folder.
public struct MachineUsage: Sendable {
    public var name: String
    /// When the file last changed: its figures are as of then.
    public var asOf: Date
    /// Totals by day, as the file gives it, then by provider.
    public var days: [String: [Provider: Tokens]]
    public init(name: String, asOf: Date, days: [String: [Provider: Tokens]]) {
        self.name = name; self.asOf = asOf; self.days = days
    }
    /// The days from `start`'s to `end`'s in this Mac's calendar, for one provider or both.
    public func tokens(_ provider: Provider? = nil, since start: Date, until end: Date,
                       timeZone: TimeZone = .current) -> Tokens {
        let first = UsageCSV.day(start, timeZone: timeZone), last = UsageCSV.day(end, timeZone: timeZone)
        var sum = Tokens()
        for (day, providers) in days where day >= first && day <= last {
            for (key, tokens) in providers where provider == nil || key == provider { sum = sum + tokens }
        }
        return sum
    }
}

/// The Other Macs folder as last read.
public struct OtherMacs: Sendable {
    public var path: String
    public var machines: [MachineUsage] = []
    /// Each file left out, and why. Its Mac's figures are left out too, never guessed.
    public var issues: [String] = []
    public init(path: String) { self.path = path }
    public var isEmpty: Bool { machines.isEmpty && issues.isEmpty }
}

public enum OtherMacsReader {
    /// Reads every CSV file in the folder, one per Mac and named after it. A file named after this
    /// Mac, in any case, is skipped: its own logs are already counted. A missing folder is no fault.
    public static func read(folder path: String, thisMac: Set<String>) -> OtherMacs {
        var result = OtherMacs(path: path)
        let root = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: root.path) else { return result }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles]) else {
            result.issues.append("Cannot read the Other Macs folder. Choose it again in Settings.")
            return result
        }
        let skipped = Set(thisMac.map { $0.lowercased() })
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where file.pathExtension.lowercased() == "csv" {
            let name = file.deletingPathExtension().lastPathComponent
            guard !skipped.contains(name.lowercased()),
                  let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            guard (values.fileSize ?? .max) <= 1_048_576, let data = try? Data(contentsOf: file),
                  let text = String(data: data, encoding: .utf8) else {
                result.issues.append("\(file.lastPathComponent) could not be read, so \(name) is left out.")
                continue
            }
            do {
                result.machines.append(MachineUsage(name: name, asOf: values.contentModificationDate ?? .distantPast,
                                                    days: try UsageCSV.parse(text)))
            } catch UsageCSV.ParseError.line(let line) {
                result.issues.append("\(file.lastPathComponent), line \(line), is not a day's totals, so \(name) is left out.")
            } catch {
                result.issues.append("\(file.lastPathComponent) is not a Tokenz CSV export, so \(name) is left out.")
            }
        }
        return result
    }
}
