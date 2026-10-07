import AppKit
import os
import SwiftUI

private let log = Logger(subsystem: "com.jbanayo.thelist", category: "window")

/// `MenuBarExtra`'s window grows when its content does but never shrinks: after switching to a
/// smaller group, or opening a task's details, the content floated in the middle of a window
/// still sized for the longest list. This keeps the window's height equal to the content's,
/// with its top edge pinned under the menu bar.
struct WindowFitter: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let height = height
        // After this layout pass, once the view is in its window.
        DispatchQueue.main.async {
            guard height > 0, let window = view.window else { return }
            let current = window.contentRect(forFrameRect: window.frame)
            guard abs(current.height - height) > 0.5 else { return }
            var frame = window.frameRect(forContentRect: NSRect(x: current.minX, y: current.minY, width: current.width, height: height))
            frame.origin.y = window.frame.maxY - frame.height // keep the top edge where it is
            window.setFrame(frame, display: true)
            log.debug("fitted window to \(height, privacy: .public)")
        }
    }
}
