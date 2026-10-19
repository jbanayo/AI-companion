import AppKit
import SwiftUI
import TheListCore

/// `TheList --render out.png [--todo path] [--today YYYY-MM-DD] [--dark] [--show-done] [--detail "task title"] [--group id] [--agent-on] [--waiting]`
/// Draws the popover and the menu bar icon for a TODO.md into PNGs without launching the app,
/// so layout can be checked from the command line.
enum Render {
    @MainActor
    static func run(_ args: [String]) -> Int32 {
        guard let out = args.first else {
            FileHandle.standardError.write(Data("usage: TheList --render out.png [--todo path] [--today YYYY-MM-DD] [--dark]\n".utf8))
            return 2
        }
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        let todoPath = value("--todo") ?? ListStore.defaultTodoPath()
        let today = value("--today") ?? TheListCore.today()
        let dark = args.contains("--dark")
        let agentOn = args.contains("--agent-on")
        // A sample session waiting on me, for the dot and the popover's list (E10.1).
        let waits = args.contains("--waiting") ? [AgentWait(
            agent: "claude", session: "sample", state: .waiting, reason: "needs permission",
            cwd: "/Users/me/AI Companion", since: Date().addingTimeInterval(-240), path: "/dev/null"
        )] : []

        let bytes = (try? Data(contentsOf: URL(fileURLWithPath: todoPath))).map { [UInt8]($0) } ?? []
        let groups = readSettings(path: settingsPath(forTodoPath: todoPath)).groups
        let filter = value("--group").map(GroupFilter.init(storageKey:)) ?? .all
        let snapshot = makeSnapshot(parseDocument(bytes), today: today, groups: groups, filter: filter)

        let detail = value("--detail").flatMap { title in
            (snapshot.groups.flatMap(\.items) + snapshot.done).first { $0.title == title }.map(PopoverView.key)
        }
        let popover = PopoverView(
            snapshot: snapshot, today: today, actions: PopoverActions(agentOn: agentOn, agentLid: agentOn, waits: waits, todoPath: todoPath), scrollable: false,
            showDone: args.contains("--show-done"), selected: detail
        )
            .background(dark ? Color(white: 0.16) : Color(white: 0.97))
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: popover)
        renderer.scale = 2
        guard let image = renderer.nsImage, write(image, to: out) else { return 1 }

        let icon = MenuBarIcon.image(for: snapshot.badge, agentMode: agentOn, waiting: !waits.isEmpty)
        let iconOut = (out as NSString).deletingPathExtension + "-icon.png"
        // The icon's non-template states resolve the label color when drawn, so draw it in the
        // appearance asked for rather than this Mac's.
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            _ = write(icon, to: iconOut, background: dark ? .black : .white)
        }
        print("wrote \(out) and \(iconOut) (badge: \(snapshot.badge.count), alert: \(snapshot.badge.alert))")
        return 0
    }

    private static func write(_ image: NSImage, to path: String, background: NSColor? = nil) -> Bool {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * 2), pixelsHigh: Int(image.size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        if let background {
            background.setFill()
            NSRect(origin: .zero, size: image.size).fill()
        }
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}
