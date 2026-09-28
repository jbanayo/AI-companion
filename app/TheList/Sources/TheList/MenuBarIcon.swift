import AppKit
import TheListCore

/// The menu bar icon with its count (E4.4). Menu bar labels are drawn as templates, which
/// ignore color, so the red "something is overdue" state has to be a non-template image.
enum MenuBarIcon {
    static func image(for badge: Badge) -> NSImage {
        let tint: NSColor = badge.alert ? .systemRed : .black
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            .applying(.init(paletteColors: [tint]))
        let symbol = NSImage(systemSymbolName: "checklist", accessibilityDescription: "The List")!
            .withSymbolConfiguration(config)!

        let text = badge.count > 0 ? "\(badge.count)" as NSString : nil
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: tint,
        ]
        let textSize = text?.size(withAttributes: attributes) ?? .zero
        let gap: CGFloat = text == nil ? 0 : 3
        let height: CGFloat = 18
        let size = NSSize(width: ceil(symbol.size.width + gap + textSize.width), height: height)

        let image = NSImage(size: size, flipped: false) { _ in
            symbol.draw(in: NSRect(x: 0, y: (height - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height))
            text?.draw(at: NSPoint(x: symbol.size.width + gap, y: (height - textSize.height) / 2), withAttributes: attributes)
            return true
        }
        image.isTemplate = !badge.alert // template: follows the menu bar's light/dark appearance
        image.accessibilityDescription = badge.alert
            ? "The List, \(badge.count) urgent, something overdue"
            : "The List, \(badge.count) urgent"
        return image
    }
}
