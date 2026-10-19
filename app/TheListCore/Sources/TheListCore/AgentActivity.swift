// E10.1, E11: what Claude Code and Codex are doing.
//
// hooks/agent-status.sh keeps one JSON file per live session in `agentsDir()` with its latest
// state, and deletes it when the session ends. This reads them back: the waiting ones drive the
// yellow dot (E10.1), and all of them pick each agent's stickman pose (E11). Codex's usage limit
// comes from its own session logs instead (see `codexLimit`).
import Foundation

public struct AgentWait: Equatable, Sendable {
    public enum State: String, Sendable {
        /// Stopped on a permission prompt or a question.
        case waiting
        /// Done with its turn, waiting for my next message.
        case finished
        /// Working: a prompt or a tool call.
        case working
        /// A turn failed because the usage limit was hit.
        case limited
    }

    /// "claude" or "codex".
    public let agent: String
    public let session: String
    public let state: State
    public let reason: String
    /// The session's working folder, "" if unknown.
    public let cwd: String
    public let since: Date
    /// The state file, for dismissing.
    public let path: String
    /// For `limited`: when usage comes back, as the agent wrote it ("3:45pm"), "" if unknown.
    public let resets: String

    public init(
        agent: String, session: String, state: State, reason: String, cwd: String, since: Date, path: String,
        resets: String = ""
    ) {
        self.agent = agent
        self.session = session
        self.state = state
        self.reason = reason
        self.cwd = cwd
        self.since = since
        self.path = path
        self.resets = resets
    }

    public var agentName: String { agent == "codex" ? "Codex" : "Claude" }
    /// The last part of `cwd`, e.g. "AI Companion".
    public var project: String { cwd.isEmpty ? "" : URL(fileURLWithPath: cwd).lastPathComponent }
    /// Shown in "Waiting on you" and counted by the yellow dot.
    public var needsMe: Bool { state == .waiting || state == .finished }
}

/// Files older than this are from sessions that died without saying so (a killed terminal).
public let agentWaitMaxAge: TimeInterval = 12 * 60 * 60
/// A working session with no new event for this long is treated as idle: tool calls refresh it,
/// so silence this long means it stopped without a hook firing (closed, crashed).
public let agentWorkingMaxAge: TimeInterval = 15 * 60
/// A usage-limit failure with no reset time stops counting after this long.
public let agentLimitedMaxAge: TimeInterval = 5 * 60 * 60

/// The folder hooks/agent-status.sh writes into: in /tmp, because Codex runs hooks inside its
/// sandbox, which can write there but not to the repo. Emptied on restart, which is fine for
/// state about running sessions.
public func agentsDir() -> String {
    "/tmp/the-companion-\(getuid())/agents"
}

/// Every live session. Malformed and stale files are skipped.
public func loadAgentSessions(dir: String, now: Date = Date()) -> [AgentWait] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    let iso = ISO8601DateFormatter()
    return names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.compactMap { name in
        let path = (dir as NSString).appendingPathComponent(name)
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let agent = json["agent"] as? String,
              let session = json["session"] as? String, !session.isEmpty,
              let state = (json["state"] as? String).flatMap(AgentWait.State.init(rawValue:)),
              let since = (json["at"] as? String).flatMap(iso.date(from:)),
              now.timeIntervalSince(since) < agentWaitMaxAge
        else { return nil }
        return AgentWait(
            agent: agent, session: session, state: state, reason: json["reason"] as? String ?? "",
            cwd: json["cwd"] as? String ?? "", since: since, path: path, resets: json["resets"] as? String ?? ""
        )
    }
}

/// Sessions waiting on me, blocked ones first, then the longest-waiting.
public func loadAgentWaits(dir: String, now: Date = Date()) -> [AgentWait] {
    agentWaits(loadAgentSessions(dir: dir, now: now))
}

public func agentWaits(_ sessions: [AgentWait]) -> [AgentWait] {
    sessions.filter(\.needsMe).sorted {
        if $0.state != $1.state { return $0.state == .waiting }
        return $0.since < $1.since
    }
}

/// "4m", "2h", "now".
public func waitedFor(_ since: Date, now: Date = Date()) -> String {
    let minutes = Int(now.timeIntervalSince(since) / 60)
    if minutes < 1 { return "now" }
    if minutes < 60 { return "\(minutes)m" }
    return "\(minutes / 60)h"
}

// MARK: - Stickman poses (E11)

public enum AgentPose: Equatable, Sendable {
    /// Working. `project` is the folder of the most recent working session.
    case running(project: String)
    /// Has usage left but nothing to do, including when it's waiting on me.
    case sitting
    /// Out of usage. `resets` is when it comes back ("3:45pm"), "" if unknown.
    case lying(resets: String)
}

/// One agent's pose. Out of usage wins, then working, then idle. A usage-limit failure stops
/// counting once any session of that agent works again, or after `agentLimitedMaxAge`.
public func agentPose(agent: String, sessions: [AgentWait], limit: AgentLimit? = nil, now: Date = Date()) -> AgentPose {
    let mine = sessions.filter { $0.agent == agent }
    let lastWork = mine.filter { $0.state == .working }.map(\.since).max()
    if let limit, limit.until > now { return .lying(resets: limit.resets) }
    if let failed = mine.filter({ $0.state == .limited }).max(by: { $0.since < $1.since }),
       now.timeIntervalSince(failed.since) < agentLimitedMaxAge,
       lastWork.map({ $0 < failed.since }) ?? true {
        return .lying(resets: failed.resets)
    }
    if let working = mine.filter({ $0.state == .working && now.timeIntervalSince($0.since) < agentWorkingMaxAge })
        .max(by: { $0.since < $1.since }) {
        return .running(project: working.project)
    }
    return .sitting
}

// MARK: - Codex usage limit (E11)

/// Out of usage until `until`.
public struct AgentLimit: Equatable, Sendable {
    public let until: Date
    /// `until` as a short local time, e.g. "3:45pm" or "Mon 9:00am".
    public let resets: String

    public init(until: Date, resets: String) {
        self.until = until
        self.resets = resets
    }
}

/// Codex writes its usage into every session log as `token_count` events with `rate_limits`.
/// The last such line in `tail` decides: out of usage when a window is at 100% or
/// `rate_limit_reached_type` is set, until that window's `resets_at`. Nil when there's usage
/// left, the reset has passed, or `tail` has no usage line.
public func codexLimit(fromLogTail tail: String, now: Date = Date()) -> AgentLimit? {
    for line in tail.split(separator: "\n").reversed() where line.contains("\"token_count\"") {
        guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let payload = json["payload"] as? [String: Any],
              let limits = payload["rate_limits"] as? [String: Any]
        else { continue }
        let reached = !(limits["rate_limit_reached_type"] is NSNull) && limits["rate_limit_reached_type"] != nil
        let windows = ["primary", "secondary"].compactMap { limits[$0] as? [String: Any] }
        let resets: [Date] = windows.compactMap { w in
            guard let at = (w["resets_at"] as? NSNumber)?.doubleValue else { return nil }
            let full = ((w["used_percent"] as? NSNumber)?.doubleValue ?? 0) >= 100
            return full || reached ? Date(timeIntervalSince1970: at) : nil
        }
        // With several full windows, usage comes back when the last of them resets.
        guard let until = resets.max(), until > now else { return nil }
        return AgentLimit(until: until, resets: shortTime(until, now: now))
    }
    return nil
}

/// The Codex session log written to most recently, among ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
/// in the last `days` day folders. By write time, not by folder: one conversation keeps writing
/// to the log in the folder of the day it started, often days ago.
public func newestCodexLog(sessionsDir: String, days: Int = 14) -> String? {
    let fm = FileManager.default
    func sub(_ dir: String) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
            .sorted(by: >).map { (dir as NSString).appendingPathComponent($0) }
    }
    let dayDirs = sub(sessionsDir).flatMap(sub).flatMap(sub).sorted(by: >).prefix(days)
    var best: (path: String, modified: Date)?
    for day in dayDirs {
        for name in (try? fm.contentsOfDirectory(atPath: day)) ?? [] where name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") {
            let path = (day as NSString).appendingPathComponent(name)
            guard let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { continue }
            if best.map({ modified > $0.modified }) ?? true { best = (path, modified) }
        }
    }
    return best?.path
}

/// The last `bytes` of a file, cut to whole lines. Reading only the end keeps this cheap however
/// long the session log gets.
public func readTail(path: String, bytes: Int = 64 * 1024) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return nil }
    let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
    try? handle.seek(toOffset: start)
    guard let data = try? handle.readToEnd() else { return nil }
    var text = String(decoding: data, as: UTF8.self)
    if start > 0, let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
    return text
}

/// "3:45pm" today, "Mon 9:00am" later.
func shortTime(_ date: Date, now: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.amSymbol = "am"
    f.pmSymbol = "pm"
    f.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "h:mma" : "EEE h:mma"
    return f.string(from: date)
}
