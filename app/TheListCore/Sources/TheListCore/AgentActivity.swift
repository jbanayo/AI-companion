// E10.1: Claude Code and Codex sessions that are waiting on me.
//
// hooks/agent-status.sh writes one JSON file per waiting session into data/agents/ and deletes
// it when the session gets going again. This reads them back.
import Foundation

public struct AgentWait: Equatable, Sendable {
    public enum State: String, Sendable {
        /// Stopped on a permission prompt or a question.
        case waiting
        /// Done with its turn, waiting for my next message.
        case finished
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

    public init(agent: String, session: String, state: State, reason: String, cwd: String, since: Date, path: String) {
        self.agent = agent
        self.session = session
        self.state = state
        self.reason = reason
        self.cwd = cwd
        self.since = since
        self.path = path
    }

    public var agentName: String { agent == "codex" ? "Codex" : "Claude" }
    /// The last part of `cwd`, e.g. "AI Companion".
    public var project: String { cwd.isEmpty ? "" : URL(fileURLWithPath: cwd).lastPathComponent }
}

/// Files older than this are from sessions that died without saying so (a killed terminal).
public let agentWaitMaxAge: TimeInterval = 12 * 60 * 60

/// The folder the hook writes into, next to TODO.md.
public func agentsDir(forTodoPath todoPath: String) -> String {
    URL(fileURLWithPath: todoPath).deletingLastPathComponent().appendingPathComponent("agents").path
}

/// Waiting sessions, blocked ones first, then the longest-waiting. Malformed and stale files
/// are skipped.
public func loadAgentWaits(dir: String, now: Date = Date()) -> [AgentWait] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    let iso = ISO8601DateFormatter()
    let waits: [AgentWait] = names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.compactMap { name in
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
            cwd: json["cwd"] as? String ?? "", since: since, path: path
        )
    }
    return waits.sorted {
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
