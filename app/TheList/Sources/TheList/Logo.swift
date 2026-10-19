import AppKit

/// The logo (chosen 2026-10-19). In the menu bar: Goku's hair, which turns Super Saiyan while
/// Saiyan mode is on. As the app icon: a Saiyan monkey tail. Drawn in code so the shapes live in
/// one place. All drawing uses top-left-origin coordinates, like the SVGs they came from.
enum Logo {
    static let ink = CGColor(srgbRed: 0x16 / 255, green: 0x18 / 255, blue: 0x1D / 255, alpha: 1)
    static let paper = CGColor(srgbRed: 0xF2 / 255, green: 0xEF / 255, blue: 0xE8 / 255, alpha: 1)
    static let coral = CGColor(srgbRed: 0xFF / 255, green: 0x5A / 255, blue: 0x36 / 255, alpha: 1)

    // MARK: - Menu bar glyph (18 pt tall, one color)

    static let menuGlyphHeight: CGFloat = 18

    /// The hair's width at menu bar size: the base hair is swept wide, Super Saiyan stands tall.
    static func menuGlyphWidth(superSaiyan: Bool) -> CGFloat { superSaiyan ? 18 : 27 }

    static func drawMenuGlyph(in cg: CGContext, color: CGColor, superSaiyan: Bool) {
        // Both outlines are on a 48-unit grid. The base hair sits in y 9...39, so it gets more of
        // the 18 pt height than Super Saiyan, which uses the full 48.
        let (points, scale, dx, dy): ([(CGFloat, CGFloat)], CGFloat, CGFloat, CGFloat) =
            superSaiyan ? (superSaiyanHair, 1.0 / 3, 3, 3) : (baseHair, 0.5, 3, -6)
        cg.saveGState()
        cg.scaleBy(x: scale, y: scale)
        cg.translateBy(x: dx, y: dy)
        cg.addPath(outline(points))
        cg.setFillColor(color)
        cg.fillPath()
        cg.restoreGState()
    }

    private static func outline(_ points: [(CGFloat, CGFloat)]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points.map { CGPoint(x: $0.0, y: $0.1) })
        path.closeSubpath()
        return path
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
        drawMark(in: cg, tail: paper, tip: coral)
        cg.restoreGState()
    }

    /// The tail in its 48-unit box: one thick curl, with a coral dot where it meets the body.
    static func drawMark(in cg: CGContext, tail: CGColor, tip: CGColor) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 14, y: 42))
        path.addCurve(to: CGPoint(x: 24, y: 25), control1: CGPoint(x: 10, y: 32), control2: CGPoint(x: 15, y: 25))
        path.addCurve(to: CGPoint(x: 36.5, y: 13), control1: CGPoint(x: 33, y: 25), control2: CGPoint(x: 38, y: 20))
        path.addCurve(to: CGPoint(x: 25.5, y: 11.5), control1: CGPoint(x: 35, y: 7), control2: CGPoint(x: 27, y: 6.5))
        path.addCurve(to: CGPoint(x: 30.5, y: 14.5), control1: CGPoint(x: 24.3, y: 15.5), control2: CGPoint(x: 28.5, y: 17.5))
        cg.addPath(path)
        cg.setStrokeColor(tail)
        cg.setLineWidth(6)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        cg.strokePath()
        cg.setFillColor(tip)
        cg.fillEllipse(in: CGRect(x: 14 - 4.5, y: 42 - 4.5, width: 9, height: 9))
    }

    // MARK: - Hair outlines (48-unit grid, traced from the reference art)

    private static let baseHair: [(CGFloat, CGFloat)] = [
        (24.9, 9), (27.1, 11.2), (28.2, 13), (29.4, 16.7), (29.7, 18), (29.9, 20.4), (32.8, 21.6), (34.4, 23.1),
        (35, 23.9), (35.5, 25), (35.7, 25.9), (35.7, 27.2), (35.9, 27.4), (38.1, 27.1), (41.7, 27.2), (43.5, 27.4),
        (46.3, 28.3), (41.7, 29.8), (39.4, 30.6), (39.1, 30.9), (41.7, 30.9), (43.6, 31.2), (46.3, 31.9), (48, 32.7),
        (42.7, 34), (39.2, 35.3), (37.6, 36.1), (37.5, 36.4), (41.8, 36.4), (42, 36.4), (42, 36.5), (33.8, 39),
        (33.6, 39), (34.5, 37.7), (35.2, 36), (35.3, 35.3), (35.3, 34.1), (35.3, 33.9), (35, 33.7), (34.5, 33.8),
        (33.7, 34.4), (32.8, 36), (31.1, 37.5), (31.7, 36.2), (31.6, 36), (30.2, 36.8), (30.9, 35.1), (31.3, 34),
        (31.1, 33.9), (29.9, 35.5), (27.9, 37.5), (28.7, 34), (28.7, 31.6), (28.4, 30.4), (27.3, 31.1), (24.9, 33.7),
        (24, 35.1), (22.7, 37.5), (22.6, 37.4), (22.4, 35.7), (22.3, 33.5), (22.4, 31.9), (23, 29.9), (22.9, 29.7),
        (22.5, 29.9), (20.9, 31.7), (20.1, 32.9), (19.4, 34.4), (19.1, 35.3), (18.9, 36.8), (18.8, 36.8), (18.6, 36.3),
        (17.8, 33.7), (17.7, 32.4), (17.8, 30.9), (17.7, 30.8), (17.1, 31.8), (16.7, 33.1), (16.5, 34.8), (16.5, 36.5),
        (16, 35.8), (15.5, 34.5), (15.3, 34.6), (15.3, 35.3), (15.7, 37.2), (15.1, 36.7), (14.7, 36), (14.2, 34.4),
        (14, 33.2), (13.5, 32.5), (13, 32.1), (12.8, 32.1), (12.6, 32.3), (12.2, 33.4), (12.2, 35.3), (12.8, 37.6),
        (8.8, 35.9), (8.8, 35.8), (10.8, 35.4), (10.9, 35.2), (10.7, 35), (5.5, 31.1), (2, 29.4), (2, 29.3),
        (4.8, 28.6), (6.9, 28.2), (7.8, 28.2), (9.9, 28.6), (10.1, 28.6), (10.1, 28.4), (8, 25.9), (6.5, 24.6),
        (3.1, 22.1), (0, 20.1), (2.8, 19.3), (6, 18.6), (9.6, 18.5), (12.9, 19.1), (17.2, 20.7), (17.3, 20.5),
        (17.3, 20), (16.7, 17.7), (15.5, 14.4), (14, 11.8), (12.1, 9.3), (14.4, 9.6), (17.1, 10.3), (19.4, 11.1),
        (21, 12), (22.9, 13.3), (24.1, 14.6), (24.9, 15.9), (25.6, 18), (25.8, 18.3), (26, 17), (26, 14.4),
    ]

    private static let superSaiyanHair: [(CGFloat, CGFloat)] = [
        (30.7, 0), (31, 3.4), (30.8, 8.9), (31, 10.8), (31.4, 12.1), (31.9, 12.1), (32.4, 10.1), (33.1, 8.2),
        (34.9, 4.8), (36.1, 3.1), (35.4, 6.3), (35.6, 9.1), (36.5, 12.9), (38.9, 18.4), (39.3, 18.3), (41.9, 13.9),
        (45.2, 10.7), (44, 13.1), (43.5, 16.5), (43.6, 21.6), (44.4, 28.7), (42.3, 32.8), (40, 36.3), (40, 36.7),
        (40.5, 36.8), (42.3, 35.7), (44.8, 34.7), (47.2, 34.1), (47.7, 34.2), (45.4, 35.4), (44.4, 36.1), (40.2, 41),
        (37, 42.2), (37.1, 42.6), (39.8, 43.4), (40.3, 43.5), (40.4, 43.9), (37.1, 43.9), (33.9, 44.6), (32.6, 46.9),
        (32.3, 46.7), (32.7, 44.9), (32.6, 42.9), (32, 43.1), (29.5, 46), (30.3, 42.1), (30, 38.6), (29.9, 38.2),
        (29.5, 38), (25.9, 37.6), (23.1, 38.2), (22.4, 39.1), (21.6, 40.7), (21, 42.5), (20.8, 44), (21, 46.5),
        (19.9, 44.8), (18.1, 40.6), (17.6, 40.6), (17.6, 42.2), (18.2, 45.4), (16.3, 42.8), (15.8, 42.8), (15.8, 44.1),
        (16.4, 45.8), (17.9, 48), (14.7, 45.8), (14.3, 45.8), (14.3, 46.4), (13.8, 46.5), (11.2, 45.8), (9.6, 45.2),
        (5.7, 43), (8, 43.7), (10.3, 44), (12.2, 43.9), (12.2, 43.4), (7.8, 39.6), (4.5, 30), (3.3, 27.8),
        (0.3, 24.4), (3.6, 26.6), (6.4, 29.3), (6.8, 29.3), (6.2, 23.5), (6.2, 20.7), (7.1, 15.6), (8.2, 12.6),
        (7.8, 15.4), (7.9, 17.8), (8.6, 20.8), (9.1, 20.9), (9.7, 17), (11.3, 12.5), (13.4, 8.5), (15.9, 5.7),
        (16.3, 5.5), (15, 7.7), (13.8, 12.8), (13.7, 15.9), (13.8, 16.3), (14.2, 16.4), (15, 14.2), (20.5, 5.9),
        (21, 4.1), (21, 6.3), (19.9, 10.4), (19.9, 10.8), (20.3, 10.9), (21.3, 9.9), (26.2, 6.4), (28.4, 4.5),
        (29.8, 2.4),
    ]

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
