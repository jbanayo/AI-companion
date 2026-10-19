import Foundation
import Observation
import TheListCore

/// E10.1: Claude Code and Codex sessions waiting on me, from the files hooks/agent-status.sh
/// writes into data/agents/. Drives the yellow dot and the popover's "Waiting on you" list.
@MainActor
@Observable
final class AgentActivity {
    private(set) var waits: [AgentWait] = []

    @ObservationIgnored let dir: String
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var timer: Timer?

    init(dir: String) {
        self.dir = dir
    }

    func start() {
        guard watcher == nil else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        reload()
        let watcher = DirectoryWatcher(path: dir) { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        watcher.start()
        self.watcher = watcher
        // Ages the "4m" labels and drops files from sessions that died without saying so.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    /// Clears one I've dealt with, or one left behind by a closed session.
    func dismiss(_ wait: AgentWait) {
        try? FileManager.default.removeItem(atPath: wait.path)
        reload()
    }

    private func reload() {
        let next = loadAgentWaits(dir: dir)
        if next != waits { waits = next }
    }
}
