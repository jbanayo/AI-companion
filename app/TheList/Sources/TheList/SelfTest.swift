import Foundation
import TheListCore

/// `TheList --selftest` drives the real ListStore the way the popover's controls do, against a
/// scratch TODO.md, and checks both the file and what the popover would show. Exit code 1 on failure.
enum SelfTest {
    @MainActor
    static func run() async -> Int32 {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("the-list-selftest-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("TODO.md").path
        try! Data("""
        # Todo

        ## P1 — This week
        - [ ] Review the PR {id:t_pr}

        ## P2 — Soon
        - [ ] Ask Raph for logos {id:t_logo}

        ## Done

        """.utf8).write(to: URL(fileURLWithPath: path))

        try! Data(#"{"proactive":true,"groups":[{"id":"byc","name":"BYC","projects":["solomon"]}]}"#.utf8)
            .write(to: dir.appendingPathComponent("settings.json"))
        let suite = "the-list-selftest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ListStore(todoPath: path, defaults: defaults)
        store.start()
        var failures = 0

        func item(_ title: String) -> ItemView? {
            (store.snapshot.groups.flatMap(\.items) + store.snapshot.done).first { $0.title == title }
        }
        func group(of title: String) -> Priority? {
            store.snapshot.groups.first { $0.items.contains { $0.title == title } }?.priority
        }
        func file() -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
        func expect(_ name: String, within seconds: Double = 2, _ condition: () -> Bool) async {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() {
                if Date() > deadline {
                    failures += 1
                    print("  FAIL \(name)\n       file now:\n\(file())")
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            print("  PASS \(name)")
        }

        print("App self-test:")
        await expect("loads the list") { store.snapshot.groups[1].count == 1 && store.snapshot.groups[2].count == 1 }

        store.toggle(item("Review the PR")!)
        await expect("tick: shows under Done, file has done:<today>") {
            item("Review the PR")?.done == true && file().contains("- [x] Review the PR {id:t_pr done:\(store.today)}")
        }

        store.toggle(item("Review the PR")!)
        await expect("untick: back under This week, where it was ticked from") {
            group(of: "Review the PR") == .p1 && file().contains("## P1 — This week\n- [ ] Review the PR {id:t_pr}")
        }

        store.move(item("Ask Raph for logos")!, to: .p3)
        await expect("move: shows under Someday, file has a P3 heading") {
            group(of: "Ask Raph for logos") == .p3 && file().contains("## P3 — Someday\n- [ ] Ask Raph for logos")
        }

        var added: Bool?
        store.add("Quick one") { added = $0 }
        await expect("quick-add: shows under Soon with src:manual") {
            added == true && group(of: "Quick one") == .p2 && file().contains("Quick one {id:") && file().contains("src:manual}")
        }

        var blank: Bool?
        store.add("   ") { blank = $0 }
        await expect("quick-add: a blank title reports nothing added") { blank == false }

        // An outside edit (a hand-typed line with no id), then tick it from the app.
        try! Data((file() + "- [ ] Typed in VS Code\n").utf8).write(to: URL(fileURLWithPath: path))
        await expect("an outside edit shows up") { item("Typed in VS Code") != nil }
        store.toggle(item("Typed in VS Code")!)
        await expect("tick a hand-typed item: it gets an id and is done") {
            item("Typed in VS Code")?.done == true && file().range(of: #"- \[x\] Typed in VS Code \{id:t_[0-9a-f]{4} done:"#, options: .regularExpression) != nil
        }

        // E8.2–E8.3: groups.
        store.setGroup(item("Quick one")!, "byc")
        await expect("move to group: the line gets group:byc") {
            store.snapshot.group(of: item("Quick one")!)?.id == "byc" && file().contains("Quick one {id:") && file().contains("group:byc src:manual}")
        }

        store.filter = .group("byc")
        await expect("filter: only BYC shows; the badge still counts everything") {
            store.snapshot.groups.flatMap(\.items).map(\.title) == ["Quick one"] && store.snapshot.badge.count == 1
        }

        var groupAdded: Bool?
        store.addGroup("Health") { groupAdded = $0 }
        await expect("new group: saved to settings.json and showing") {
            groupAdded == true && store.snapshot.filter == .group("health") && store.snapshot.isEmpty
                && ((try? String(contentsOf: dir.appendingPathComponent("settings.json"), encoding: .utf8)) ?? "").contains("\"Health\"")
        }

        store.add("Gym") { _ in }
        await expect("quick-add while a group shows: filed in that group") {
            item("Gym") != nil && file().contains("group:health src:manual}")
        }

        try! Data(#"{"proactive":true,"groups":[]}"#.utf8).write(to: dir.appendingPathComponent("settings.json"))
        await expect("groups removed by hand: back to All") {
            store.snapshot.filter == .all && store.snapshot.taskGroups.isEmpty && item("Review the PR") != nil
        }

        // E9, E11: Saiyan mode, against a fake so nothing touches power settings or asks for a password.
        let power = FakePower()
        let agent = AgentMode(power: power)
        agent.setOn(true)
        await expect("Saiyan mode on: screen assertion held, lid awake, one password prompt that installs the rule") {
            !agent.busy && agent.isOn && agent.lidAwake && power.holding && power.lid && power.prompts == 1 && power.rule
        }
        agent.setOn(false)
        await expect("Saiyan mode off: assertion released, lid sleeps again, no password prompt") {
            !agent.busy && !agent.isOn && !power.holding && !power.lid && power.prompts == 1
        }
        agent.setOn(true)
        await expect("on again: asks for the password") { !agent.busy && agent.lidAwake && power.prompts == 2 }
        power.rule = false
        agent.setOn(false)
        await expect("off without the rule: falls back to the password prompt") {
            !agent.busy && !agent.isOn && !power.lid && power.prompts == 3
        }
        power.refuseLid = true
        agent.setOn(true)
        await expect("password cancelled: still on for the screen, says the lid will sleep") {
            !agent.busy && agent.isOn && !agent.lidAwake && agent.message != nil
        }
        agent.shutdown()
        await expect("quit: assertion released") { !agent.isOn && !power.holding }

        // E12.2: When agents finish, with a short grace so it runs in under a second.
        power.refuseLid = false
        power.rule = true
        func session(_ state: AgentWait.State) -> AgentWait {
            AgentWait(agent: "claude", session: "s", state: state, reason: "", cwd: "/x/proj", since: Date(), path: "")
        }
        let after = AfterAgents(agent: agent, power: power, grace: 0.3)
        agent.setOn(true)
        await expect("Saiyan on again for E12.2") { !agent.busy && agent.lidAwake }
        after.arm(.sleep)
        after.update([session(.finished)])
        try? await Task.sleep(for: .seconds(0.6))
        await expect("armed with nothing working: doesn't fire") {
            after.action == .sleep && after.remaining == nil && agent.isOn && power.sleeps == 0
        }
        after.update([session(.working)])
        await expect("working: lists it, no countdown") { after.busy.count == 1 && after.remaining == nil }
        after.update([session(.finished)])
        await expect("all done: counts down") { after.remaining != nil }
        after.update([session(.working)])
        await expect("work again: the countdown stops") { after.remaining == nil && after.action == .sleep }
        var prompts = power.prompts
        after.update([session(.waiting)])
        await expect("done for the grace: Saiyan off without a password, then sleep, then disarmed") {
            power.sleeps == 1 && !agent.isOn && !agent.lidAwake && after.action == nil && power.prompts == prompts
        }
        agent.setOn(true)
        await expect("Saiyan on for shut down") { !agent.busy && agent.lidAwake }
        after.arm(.shutDown)
        after.update([session(.working)])
        after.update([])
        await expect("a session that ended counts as done: shuts down") { power.shutdowns == 1 && !agent.isOn }
        agent.setOn(true)
        await expect("Saiyan on for turn-off-only") { !agent.busy && agent.lidAwake }
        power.rule = false
        prompts = power.prompts
        after.arm(.saiyanOff)
        after.update([session(.working)])
        after.update([session(.finished)])
        await expect("Turn off Saiyan without the sudoers rule: no prompt, screen part off, no sleep") {
            !agent.busy && !power.holding && power.prompts == prompts && power.sleeps == 1 && power.shutdowns == 1
                && after.action == nil
        }
        agent.shutdown()
        let off = MenuBarIcon.image(for: Badge(count: 2, alert: false))
        let on = MenuBarIcon.image(for: Badge(count: 2, alert: false), agentMode: true)
        let due = MenuBarIcon.image(for: Badge(count: 2, alert: true))
        await expect("menu bar icon: Super Saiyan hair is narrower, says Saiyan mode") {
            on.size.width < off.size.width && (on.accessibilityDescription ?? "").contains("Saiyan mode on")
        }
        await expect("menu bar icon: due today adds the dot and drops the template") {
            due.size.width > off.size.width && off.isTemplate && !due.isTemplate
                && (due.accessibilityDescription ?? "").contains("due today")
        }
        let waiting = MenuBarIcon.image(for: Badge(count: 2, alert: false), waiting: true)
        let both = MenuBarIcon.image(for: Badge(count: 2, alert: true), waiting: true)
        await expect("menu bar icon: waiting adds the yellow dot; both dots fit side by side") {
            !waiting.isTemplate && waiting.size.width == due.size.width && both.size.width > due.size.width
                && (waiting.accessibilityDescription ?? "").contains("waiting on you")
        }

        try? FileManager.default.removeItem(at: dir)
        print(failures == 0 ? "all passed" : "\(failures) failed")
        return failures == 0 ? 0 : 1
    }
}

/// Stands in for `SystemPower` in the self-test.
private final class FakePower: PowerControl, @unchecked Sendable {
    private let lock = NSLock()
    private var _lid = false
    private var _prompts = 0
    private var _rule = false
    var holding = false
    var refuseLid = false
    var lid: Bool { lock.withLock { _lid } }
    /// Password prompts shown.
    var prompts: Int { lock.withLock { _prompts } }
    /// The sudoers rule for a quiet off is installed.
    var rule: Bool {
        get { lock.withLock { _rule } }
        set { lock.withLock { _rule = newValue } }
    }

    @MainActor func holdAwake() -> Bool { holding = true; return true }
    @MainActor func releaseAwake() { holding = false }
    func lidAwake() -> Bool { lid }
    func setLidAwake(_ on: Bool) throws {
        lock.withLock { _prompts += 1 }
        if lock.withLock({ refuseLid }) { throw PowerError(description: "User canceled. (-128)") }
        lock.withLock { _lid = on; _rule = true }
    }
    func releaseLidQuietly() -> Bool {
        lock.withLock {
            guard _rule else { return false }
            _lid = false
            return true
        }
    }
    private var _sleeps = 0
    private var _shutdowns = 0
    var sleeps: Int { lock.withLock { _sleeps } }
    var shutdowns: Int { lock.withLock { _shutdowns } }
    func sleepNow() throws {
        try lock.withLock {
            if _lid { throw PowerError(description: "sleep is disabled") }
            _sleeps += 1
        }
    }
    func shutDown() throws { lock.withLock { _shutdowns += 1 } }
}
