import AppKit
import TheListCore

/// The menu bar icon with its count (E4.4). The hair turns Super Saiyan while agent mode is on
/// (E9), and a coral dot appears when something is due today or overdue. Menu bar labels are
/// drawn as templates, which ignore color, so the dot state has to be a non-template image; the
/// hair and count then use the label color, resolved when drawn, to keep following light/dark.
enum MenuBarIcon {
    static func image(for badge: Badge, agentMode: Bool = false) -> NSImage {
        let text = badge.count > 0 ? "\(badge.count)" as NSString : nil
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let textSize = text?.size(withAttributes: [.font: font]) ?? .zero
        let glyphWidth = Logo.menuGlyphWidth(superSaiyan: agentMode)
        let dot: CGFloat = badge.alert ? 5 : 0
        let dotGap: CGFloat = badge.alert ? 1 : 0
        let gap: CGFloat = text == nil ? 0 : 3
        let height = Logo.menuGlyphHeight
        let size = NSSize(width: ceil(glyphWidth + dotGap + dot + gap + textSize.width), height: height)

        let image = NSImage(size: size, flipped: true) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            // Templates are tinted by the menu bar, so black is right there.
            let tint: NSColor = badge.alert ? .labelColor : .black
            Logo.drawMenuGlyph(in: cg, color: tint.cgColor, superSaiyan: agentMode)
            if badge.alert {
                cg.setFillColor(Logo.coral)
                cg.fillEllipse(in: CGRect(x: glyphWidth + dotGap, y: 2, width: dot, height: dot))
            }
            text?.draw(
                at: NSPoint(x: glyphWidth + dotGap + dot + gap, y: (height - textSize.height) / 2),
                withAttributes: [.font: font, .foregroundColor: tint]
            )
            return true
        }
        image.isTemplate = !badge.alert // template: follows the menu bar's light/dark appearance
        let due = badge.alert ? ", something due today or overdue" : ""
        let agent = agentMode ? ", agent mode on" : ""
        image.accessibilityDescription = "The Companion, \(badge.count) urgent\(due)\(agent)"
        return image
    }
}
