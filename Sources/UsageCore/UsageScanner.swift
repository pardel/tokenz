import Foundation

/// Serial, incremental reader. Keeps numeric usage records in memory; never writes session data.
public final class UsageScanner: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: FileState] = [:]
    private var claudeQuota: QuotaSnapshot?
    private var quotaPath: String?
    public init() {}
    public func scan(paths: [Provider: String], claudeQuotaPath: String? = nil, now: Date = Date()) -> UsageSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let calendar = Calendar.current
        let cutoff = UsagePeriod.thirtyDays.start(at: now, calendar: calendar)
        if quotaPath != claudeQuotaPath { claudeQuota = nil; quotaPath = claudeQuotaPath }
        if let path = claudeQuotaPath, let report = ClaudeQuotaReader.read(from: path) {
            if report.date >= (claudeQuota?.date ?? .distantPast) { claudeQuota = report }
        }
        var activePaths = Set<String>()
        let providers = Provider.allCases.map { provider -> ProviderUsage in
            let path = paths[provider] ?? ""
            var result = ProviderUsage(provider: provider, path: path)
            if provider == .claude { result.quota = claudeQuota }
            let root = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                result.issue = "Session folder not found. Choose your \(provider.title) folder in Settings."
                return result
            }
            guard FileManager.default.isReadableFile(atPath: root.path) else {
                result.issue = "Cannot read this folder. Choose an accessible session folder in Settings."
                return result
            }
            var readFailures = 0
            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles], errorHandler: { _, _ in readFailures += 1; return true }) else {
                result.issue = "Cannot list session files. Choose the folder again in Settings."
                return result
            }
            var unique: [String: UsageRecord] = [:]
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let cacheKey = "\(provider.rawValue)|\(url.path)"
                activePaths.insert(cacheKey)
                guard let attributes = try? url.resourceValues(forKeys: Set(keys)), attributes.isRegularFile == true else { continue }
                result.files += 1
                let size = UInt64(attributes.fileSize ?? 0)
                let modified = attributes.contentModificationDate ?? .distantPast
                if modified < cutoff && cache[cacheKey] == nil { continue }
                var state = cache[cacheKey] ?? FileState()
                if size < state.offset || (size == state.offset && modified != state.modified) {
                    state = FileState() // Truncated or replaced log.
                }
                if state.session.isEmpty { state.session = url.deletingPathExtension().lastPathComponent }
                if size > state.offset {
                    do { try read(url, provider: provider, state: &state, cutoff: cutoff) }
                    catch { readFailures += 1 }
                }
                state.modified = modified
                state.records = state.records.filter { $0.value.date >= cutoff }
                cache[cacheKey] = state
                for (key, record) in state.records {
                    if let previous = unique[key] {
                        var merged = previous
                        merged.tokens = previous.tokens.merged(with: record.tokens)
                        merged.date = min(previous.date, record.date)
                        merged.session = min(previous.session, record.session)
                        unique[key] = merged
                    } else { unique[key] = record }
                }
                if let quota = state.quota, quota.date > (result.quota?.date ?? .distantPast) { result.quota = quota }
            }
            result.records = Array(unique.values)
            if readFailures > 0 { result.issue = "\(readFailures) file(s) could not be read. Totals may be incomplete." }
            else if result.files == 0 { result.issue = "No session logs yet. Run \(provider.title), then refresh." }
            return result
        }
        cache = cache.filter { activePaths.contains($0.key) }
        return UsageSnapshot(providers: providers, refreshedAt: now)
    }

    private func read(_ url: URL, provider: Provider, state: inout FileState, cutoff: Date) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: state.offset)
        var pending = Data()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            pending.append(chunk)
            var start = pending.startIndex
            while let newline = pending[start...].firstIndex(of: 10) {
                LogParser.consume(pending.subdata(in: start..<newline), provider: provider, state: &state, cutoff: cutoff)
                state.offset += UInt64(newline - start + 1)
                start = newline + 1
            }
            if start > pending.startIndex { pending = Data(pending[start...]) }
            // An active writer's unfinished final line is reread on the next poll.
        }
    }
}
