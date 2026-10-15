import AppKit
import TheListCore

/// The menu bar icon with its count (E4.4), and a bolt while agent mode is on (E9). Menu bar
/// labels are drawn as templates, which ignore color, so the red "something is overdue" state
/// has to be a non-template image.
enum MenuBarIcon {
    static func image(for badge: Badge, agentMode: Bool = false) -> NSImage {
        let tint: NSColor = badge.alert ? .systemRed : .black

        let text = badge.count > 0 ? "\(badge.count)" as NSString : nil
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: tint,
        ]
        let textSize = text?.size(withAttributes: attributes) ?? .zero
        let bolt = agentMode ? boltImage(tint: tint) : nil
        let boltSize = bolt?.size ?? .zero
        let glyph = Logo.menuGlyphSize
        let boltGap: CGFloat = bolt == nil ? 0 : 2
        let gap: CGFloat = text == nil ? 0 : 3
        let height: CGFloat = 18
        let size = NSSize(width: ceil(glyph + boltGap + boltSize.width + gap + textSize.width), height: height)

        let image = NSImage(size: size, flipped: true) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            cg.saveGState()
            cg.translateBy(x: 0, y: (height - glyph) / 2)
            Logo.drawMenuGlyph(in: cg, color: tint.cgColor)
            cg.restoreGState()
            bolt?.draw(in: NSRect(
                origin: NSPoint(x: glyph + boltGap, y: (height - boltSize.height) / 2), size: boltSize
            ))
            text?.draw(
                at: NSPoint(x: glyph + boltGap + boltSize.width + gap, y: (height - textSize.height) / 2),
                withAttributes: attributes
            )
            return true
        }
        image.isTemplate = !badge.alert // template: follows the menu bar's light/dark appearance
        let overdue = badge.alert ? ", something overdue" : ""
        let agent = agentMode ? ", agent mode on" : ""
        image.accessibilityDescription = "The Companion, \(badge.count) urgent\(overdue)\(agent)"
        return image
    }

    private static func boltImage(tint: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
            .applying(.init(paletteColors: [tint]))
        return NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }
}
