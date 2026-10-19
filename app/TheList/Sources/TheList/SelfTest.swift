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

        // E9: agent mode, against a fake so nothing touches power settings or asks for a password.
        let power = FakePower()
        let agent = AgentMode(power: power)
        agent.setOn(true)
        await expect("agent mode on: screen assertion held, lid awake, shows as on") {
            !agent.busy && agent.isOn && agent.lidAwake && power.holding && power.lid
        }
        agent.setOn(false)
        await expect("agent mode off: assertion released, lid sleeps again") {
            !agent.busy && !agent.isOn && !power.holding && !power.lid
        }
        power.refuseLid = true
        agent.setOn(true)
        await expect("password cancelled: still on for the screen, says the lid will sleep") {
            !agent.busy && agent.isOn && !agent.lidAwake && agent.message != nil
        }
        agent.shutdown()
        await expect("quit: assertion released") { !agent.isOn && !power.holding }
        let off = MenuBarIcon.image(for: Badge(count: 2, alert: false))
        let on = MenuBarIcon.image(for: Badge(count: 2, alert: false), agentMode: true)
        let due = MenuBarIcon.image(for: Badge(count: 2, alert: true))
        await expect("menu bar icon: Super Saiyan hair is narrower, says agent mode") {
            on.size.width < off.size.width && (on.accessibilityDescription ?? "").contains("agent mode on")
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
    var holding = false
    var refuseLid = false
    var lid: Bool { lock.withLock { _lid } }

    @MainActor func holdAwake() -> Bool { holding = true; return true }
    @MainActor func releaseAwake() { holding = false }
    func lidAwake() -> Bool { lid }
    func setLidAwake(_ on: Bool) throws {
        if lock.withLock({ refuseLid }) { throw PowerError(description: "User canceled. (-128)") }
        lock.withLock { _lid = on }
    }
}
