import AppKit

/// The "Stack" logo (chosen 2026-10-04): three list rows getting shorter, the top one marked as
/// urgent. Drawn in code so the menu bar icon and the app icon come from one source.
/// All drawing uses top-left-origin coordinates, like the SVG it came from.
enum Logo {
    static let ink = CGColor(srgbRed: 0x16 / 255, green: 0x18 / 255, blue: 0x1D / 255, alpha: 1)
    static let paper = CGColor(srgbRed: 0xF2 / 255, green: 0xEF / 255, blue: 0xE8 / 255, alpha: 1)
    static let coral = CGColor(srgbRed: 0xFF / 255, green: 0x5A / 255, blue: 0x36 / 255, alpha: 1)

    // MARK: - Menu bar glyph (18 × 18 pt, one color)

    static let menuGlyphSize: CGFloat = 18

    static func drawMenuGlyph(in cg: CGContext, color: CGColor) {
        cg.setFillColor(color)
        cg.setStrokeColor(color)
        cg.setLineWidth(1.1)
        cg.fillEllipse(in: circle(3.2, 4.5, 1.8))
        cg.strokeEllipse(in: circle(3.2, 9, 1.4))
        cg.strokeEllipse(in: circle(3.2, 13.5, 1.4))
        for (y, width) in [(3.5, 10.0), (8, 7.5), (12.5, 5)] as [(CGFloat, CGFloat)] {
            cg.addPath(CGPath(roundedRect: CGRect(x: 6.5, y: y, width: width, height: 2), cornerWidth: 1, cornerHeight: 1, transform: nil))
            cg.fillPath()
        }
    }

    // MARK: - App icon

    /// The app icon at `pixels` × `pixels`, following macOS's icon grid: the rounded square
    /// takes 824 of 1024, centered, so it lines up with other apps in Finder and Settings.
    static func drawAppIcon(in cg: CGContext, pixels: CGFloat) {
        let unit = pixels / 1024
        let body = CGRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
        cg.addPath(CGPath(roundedRect: body, cornerWidth: 185 * unit, cornerHeight: 185 * unit, transform: nil))
        cg.setFillColor(ink)
        cg.fillPath()

        // The mark is 48 units square and fills 60% of the body (as in the design: 60 of 100).
        cg.saveGState()
        cg.translateBy(x: body.minX + body.width * 0.2, y: body.minY + body.height * 0.2)
        cg.scaleBy(x: body.width * 0.6 / 48, y: body.width * 0.6 / 48)
        // At 32 px and below the outline circles turn to mush, so only the bars and the dot stay.
        drawMark(in: cg, rows: paper, urgent: coral, rings: pixels > 32)
        cg.restoreGState()
    }

    /// The mark in its 48-unit box.
    static func drawMark(in cg: CGContext, rows: CGColor, urgent: CGColor, rings: Bool = true) {
        cg.setFillColor(urgent)
        cg.fillEllipse(in: circle(10, 12, 4.5))
        if rings {
            cg.setStrokeColor(rows)
            cg.setLineWidth(2.4)
            cg.strokeEllipse(in: circle(10, 24, 3.6))
            cg.strokeEllipse(in: circle(10, 36, 3.6))
        }
        cg.setFillColor(rows)
        for (y, width) in [(9, 24), (21, 18), (33, 12)] as [(CGFloat, CGFloat)] {
            cg.addPath(CGPath(roundedRect: CGRect(x: 19, y: y, width: width, height: 6), cornerWidth: 3, cornerHeight: 3, transform: nil))
            cg.fillPath()
        }
    }

    private static func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> CGRect {
        CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
    }

    // MARK: - Iconset (for build-app.sh)

    /// `TheList --make-iconset AppIcon.iconset` writes the PNGs `iconutil` turns into AppIcon.icns.
    static func writeIconset(to dir: String) -> Int32 {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = points * scale
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0
                )!
                NSGraphicsContext.saveGraphicsState()
                let context = NSGraphicsContext(bitmapImageRep: rep)!
                NSGraphicsContext.current = context
                let cg = context.cgContext
                cg.translateBy(x: 0, y: CGFloat(pixels)) // top-left origin
                cg.scaleBy(x: 1, y: -1)
                drawAppIcon(in: cg, pixels: CGFloat(pixels))
                NSGraphicsContext.restoreGraphicsState()

                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                guard let png = rep.representation(using: .png, properties: [:]),
                      (try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))) != nil else {
                    FileHandle.standardError.write(Data("couldn't write \(name)\n".utf8))
                    return 1
                }
            }
        }
        return 0
    }
}
