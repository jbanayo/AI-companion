import SwiftUI
import TheListCore

@main
enum Entry {
    @MainActor
    static func main() {
        if let i = CommandLine.arguments.firstIndex(of: "--render") {
            exit(Render.run(Array(CommandLine.arguments[(i + 1)...])))
        }
        if let i = CommandLine.arguments.firstIndex(of: "--make-iconset"), CommandLine.arguments.indices.contains(i + 1) {
            exit(Logo.writeIconset(to: CommandLine.arguments[i + 1]))
        }
        if CommandLine.arguments.contains("--selftest") {
            Task { @MainActor in exit(await SelfTest.run()) }
            RunLoop.main.run()
        }
        TheListApp.main()
    }
}

struct TheListApp: App {
    @State private var store: ListStore = {
        let store = ListStore(todoPath: ListStore.defaultTodoPath())
        store.start()
        return store
    }()
    @State private var activity: AgentActivity
    @State private var agent: AgentMode
    @State private var after: AfterAgents

    init() {
        let agent = AgentMode()
        agent.refresh()
        let after = AfterAgents(agent: agent)
        let activity = AgentActivity(dir: agentsDir())
        activity.onReload = after.update
        activity.start()
        _activity = State(initialValue: activity)
        _agent = State(initialValue: agent)
        _after = State(initialValue: after)
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(snapshot: store.snapshot, today: store.today, actions: PopoverActions(
                toggle: store.toggle,
                open: store.open,
                move: store.move,
                add: store.add,
                selectFilter: { store.filter = $0 },
                setGroup: store.setGroup,
                addGroup: store.addGroup,
                exportReminders: store.exportReminders,
                exporting: store.exporting,
                agentOn: agent.isOn,
                agentLid: agent.lidAwake,
                agentBusy: agent.busy,
                setAgent: { on in
                    agent.setOn(on)
                    if !on { after.arm(nil) }
                },
                afterAction: after.action,
                afterBusy: after.busy,
                afterRemaining: after.remaining,
                setAfter: after.arm,
                waits: activity.waits,
                dismissWait: activity.dismiss,
                claude: activity.claude,
                codex: activity.codex,
                quit: {
                    agent.shutdown()
                    NSApplication.shared.terminate(nil)
                },
                openURL: store.openURL,
                reveal: store.reveal,
                todoPath: store.todoPath,
                message: agent.message ?? store.message,
                messageIsError: agent.message != nil || store.messageIsError
            ))
        } label: {
            Image(nsImage: MenuBarIcon.image(
                for: store.snapshot.badge, agentMode: agent.isOn, waiting: !activity.waits.isEmpty
            ))
        }
        .menuBarExtraStyle(.window)
    }
}
