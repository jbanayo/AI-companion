import Foundation
import Observation
import TheListCore

/// E10.1, E11, E12: what Claude Code, Codex and Antigravity are doing, from the files
/// hooks/agent-status.sh writes into `agentsDir()`, plus Codex's usage limit from its session logs.
/// Drives the yellow dot, the popover's "Waiting on you" list, the two stickmen and "When agents
/// finish".
@MainActor
@Observable
final class AgentActivity {
    private(set) var waits: [AgentWait] = []
    private(set) var claude: AgentPose = .sitting
    private(set) var codex: AgentPose = .sitting

    @ObservationIgnored let dir: String
    @ObservationIgnored private let codexSessions: String
    @ObservationIgnored private var sessions: [AgentWait] = []
    @ObservationIgnored private var codexLimit: AgentLimit?
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var timer: Timer?
    /// E12.2: every reload's sessions, for "When agents finish".
    @ObservationIgnored var onReload: @MainActor ([AgentWait]) -> Void = { _ in }

    init(dir: String, codexSessions: String = NSHomeDirectory() + "/.codex/sessions") {
        self.dir = dir
        self.codexSessions = codexSessions
    }

    func start() {
        guard watcher == nil else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        readCodexLimit()
        reload()
        let watcher = DirectoryWatcher(path: dir) { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        watcher.start()
        self.watcher = watcher
        // Once a minute: ages the "4m" labels, lets stale sessions go, and re-reads the end of
        // Codex's newest log (64 KB at most) for its usage limit.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.readCodexLimit()
                self?.reload()
            }
        }
    }

    /// Clears one I've dealt with, or one left behind by a closed session.
    func dismiss(_ wait: AgentWait) {
        try? FileManager.default.removeItem(atPath: wait.path)
        reload()
    }

    private func reload() {
        let now = Date()
        sessions = loadAgentSessions(dir: dir, now: now)
        set(\.waits, agentWaits(sessions))
        set(\.claude, agentPose(agent: "claude", sessions: sessions, now: now))
        set(\.codex, agentPose(agent: "codex", sessions: sessions, limit: codexLimit, now: now))
        onReload(sessions)
    }

    private func readCodexLimit() {
        codexLimit = newestCodexLog(sessionsDir: codexSessions)
            .flatMap { readTail(path: $0) }
            .flatMap { TheListCore.codexLimit(fromLogTail: $0) }
    }

    /// Assigns only on a real change, so the popover doesn't redraw every minute for nothing.
    private func set<T: Equatable>(_ key: ReferenceWritableKeyPath<AgentActivity, T>, _ value: T) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
    }
}
