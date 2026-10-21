import Foundation
import Observation
import os
import TheListCore

private let log = Logger(subsystem: "com.jbanayo.thelist", category: "after-agents")

/// E12.2 "When agents finish": picked under Saiyan mode. Once every Claude Code, Codex and
/// Antigravity session has stopped working and stayed stopped for `afterAgentsGrace`, it turns
/// Saiyan mode off and then, depending on the pick, sleeps or shuts down the Mac. Then it
/// disarms. Not remembered across launches, like Saiyan mode.
@MainActor
@Observable
final class AfterAgents {
    enum Action: String, CaseIterable, Sendable {
        case saiyanOff, sleep, shutDown

        var label: String {
            switch self {
            case .saiyanOff: "Turn off Saiyan"
            case .sleep: "Sleep"
            case .shutDown: "Shut down"
            }
        }

        /// "Sleeping in 1:52".
        var doing: String {
            switch self {
            case .saiyanOff: "Turning Saiyan off"
            case .sleep: "Sleeping"
            case .shutDown: "Shutting down"
            }
        }
    }

    /// nil: keep the Mac awake, as before.
    private(set) var action: Action?
    /// The working sessions it's waiting on.
    private(set) var busy: [AgentWait] = []
    /// Whole seconds left while counting down, else nil.
    private(set) var remaining: Int?

    @ObservationIgnored private let agent: AgentMode
    @ObservationIgnored private let power: PowerControl
    @ObservationIgnored private let grace: TimeInterval
    @ObservationIgnored private var clock: AfterAgentsClock
    @ObservationIgnored private var sessions: [AgentWait] = []
    @ObservationIgnored private var tick: Timer?

    /// `grace` is shorter in `--selftest`.
    init(agent: AgentMode, power: PowerControl = SystemPower(), grace: TimeInterval = afterAgentsGrace) {
        self.agent = agent
        self.power = power
        self.grace = grace
        clock = AfterAgentsClock(grace: grace)
    }

    /// Pick an action, or nil to disarm. Starts fresh: it waits for work to happen and stop again.
    func arm(_ action: Action?) {
        self.action = action
        clock = AfterAgentsClock(grace: grace)
        update(sessions)
    }

    /// Called on every reload of the agents' state files.
    func update(_ sessions: [AgentWait]) {
        self.sessions = sessions
        let working = sessions.filter { $0.state == .working }
        if busy != working { busy = working }
        if action != nil { clock.update(sessions) }
        step()
    }

    /// Once a second while counting down: shows the time left, and acts when it runs out.
    private func step() {
        guard let action, let left = clock.remaining() else { return stop() }
        if left == 0 { return fire(action) }
        remaining = Int(left.rounded(.up))
        guard tick == nil else { return }
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.step() }
        }
    }

    private func stop() {
        tick?.invalidate()
        tick = nil
        remaining = nil
    }

    private func fire(_ action: Action) {
        log.info("agents done: \(action.rawValue, privacy: .public)")
        self.action = nil
        clock = AfterAgentsClock(grace: grace)
        stop()
        agent.setOn(false, askPassword: false)
        guard action != .saiyanOff else { return }
        let agent = agent, power = power
        Task { @MainActor in
            // Lid sleep comes back off the main thread; sleeping before it does would be refused.
            while agent.busy { try? await Task.sleep(for: .milliseconds(100)) }
            let result = await Task.detached { Result { try action == .sleep ? power.sleepNow() : power.shutDown() } }.value
            if case let .failure(error) = result {
                log.error("\(action.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
                agent.show(action == .sleep ? "Couldn't sleep the Mac." : "Couldn't shut down. Allow The Companion to control System Events.")
            }
        }
    }
}
