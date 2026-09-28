import SwiftUI
import TheListCore

@main
enum Entry {
    @MainActor
    static func main() {
        if let i = CommandLine.arguments.firstIndex(of: "--render") {
            exit(Render.run(Array(CommandLine.arguments[(i + 1)...])))
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

    var body: some Scene {
        MenuBarExtra {
            PopoverView(snapshot: store.snapshot, today: store.today, actions: PopoverActions(
                toggle: store.toggle,
                open: store.open,
                move: store.move,
                add: store.add,
                quit: { NSApplication.shared.terminate(nil) },
                message: store.message
            ))
        } label: {
            Image(nsImage: MenuBarIcon.image(for: store.snapshot.badge))
        }
        .menuBarExtraStyle(.window)
    }
}
