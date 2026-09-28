import SwiftUI
import TheListCore

@main
enum Entry {
    @MainActor
    static func main() {
        if let i = CommandLine.arguments.firstIndex(of: "--render") {
            exit(Render.run(Array(CommandLine.arguments[(i + 1)...])))
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
            PopoverView(snapshot: store.snapshot, today: store.today)
        } label: {
            Image(nsImage: MenuBarIcon.image(for: store.snapshot.badge))
        }
        .menuBarExtraStyle(.window)
    }
}
