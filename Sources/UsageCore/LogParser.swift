import Foundation

struct FileState {
    var offset: UInt64 = 0
    var modified: Date = .distantPast
    var session = ""
    var previous: Tokens?
    var records: [String: UsageRecord] = [:]
    var quota: QuotaSnapshot?
}

enum LogParser {
    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    static let plain = ISO8601DateFormatter()
    static func date(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        return fractional.date(from: value) ?? plain.date(from: value)
    }
    static func number(_ dict: [String: Any], _ key: String) -> Int64 {
        max(0, (dict[key] as? NSNumber)?.int64Value ?? 0)
    }
    static func codexTokens(_ dict: [String: Any]) -> Tokens {
        let input = number(dict, "input_tokens")
        return Tokens(input: input, output: number(dict, "output_tokens"),
                      cached: min(input, number(dict, "cached_input_tokens")),
                      cacheWrite: min(input, number(dict, "cache_write_input_tokens")))
    }
    static func consume(_ data: Data, provider: Provider, state: inout FileState, cutoff: Date) {
        // Discard non-usage lines before JSON decoding. Never retain prompts or tool output.
        let marker = provider == .claude ? Data("\"usage\"".utf8) : Data("\"token_count\"".utf8)
        let isMeta = provider == .codex && data.range(of: Data("\"session_meta\"".utf8)) != nil
        guard isMeta || data.range(of: marker) != nil,
              let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if isMeta, row["type"] as? String == "session_meta",
           let meta = row["payload"] as? [String: Any], let id = meta["id"] as? String {
            state.session = id
            return
        }
        guard let timestamp = date(row["timestamp"]) else { return }
        if provider == .claude {
            guard row["type"] as? String == "assistant",
                  let message = row["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any], timestamp >= cutoff else { return }
            let cached = number(usage, "cache_read_input_tokens")
            let write = number(usage, "cache_creation_input_tokens")
            let tokens = Tokens(input: number(usage, "input_tokens") + cached + write,
                                output: number(usage, "output_tokens"), cached: cached, cacheWrite: write)
            guard tokens.total > 0 else { return }
            // Claude emits the same message for each content block and copied transcripts.
            let messageID = message["id"] as? String ?? row["uuid"] as? String
            guard let messageID else { return }
            let key = "claude|\(messageID)|\(row["requestId"] as? String ?? "")"
            let session = row["sessionId"] as? String ?? state.session
            if let existing = state.records[key] {
                state.records[key]?.tokens = existing.tokens.merged(with: tokens)
            } else {
                state.records[key] = UsageRecord(key: key, date: timestamp, tokens: tokens, session: session)
            }
        } else {
            guard row["type"] as? String == "event_msg",
                  let payload = row["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count" else { return }
            if let raw = payload["rate_limits"] as? [String: Any] {
                let windows = ["primary", "secondary"].compactMap { key -> QuotaWindow? in
                    guard let window = raw[key] as? [String: Any],
                          let percent = window["used_percent"] as? NSNumber,
                          let minutes = window["window_minutes"] as? NSNumber else { return nil }
                    let reset = (window["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                    return QuotaWindow(id: key, usedPercent: min(100, max(0, percent.doubleValue)),
                                       minutes: minutes.intValue, resetsAt: reset)
                }
                if !windows.isEmpty, timestamp >= (state.quota?.date ?? .distantPast) {
                    state.quota = QuotaSnapshot(date: timestamp, windows: windows)
                }
            }
            guard let info = payload["info"] as? [String: Any],
                  let totalRaw = info["total_token_usage"] as? [String: Any] else { return }
            let total = codexTokens(totalRaw)
            let last = (info["last_token_usage"] as? [String: Any]).map(codexTokens)
            let increment: Tokens
            if let previous = state.previous {
                if previous == total { return } // Repeated status updates are not new usage.
                if total.input >= previous.input && total.output >= previous.output {
                    increment = Tokens(input: total.input - previous.input, output: total.output - previous.output,
                                       cached: max(0, total.cached - previous.cached),
                                       cacheWrite: max(0, total.cacheWrite - previous.cacheWrite))
                } else { increment = last ?? total } // Compaction or counter reset.
            } else { increment = last ?? total } // A resumed/forked log may inherit a large total.
            state.previous = total
            guard timestamp >= cutoff, increment.total > 0 else { return }
            // Forks can copy historical events under a new session ID. The original
            // event's timestamp and counters survive the copy, so deduplicate those.
            let key = "codex|\(row["timestamp"] as? String ?? "")|\(total.input)|\(total.output)|\(total.cached)|\(total.cacheWrite)"
            state.records[key] = UsageRecord(key: key, date: timestamp, tokens: increment, session: state.session)
        }
    }
}
