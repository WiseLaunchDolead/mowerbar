import AppKit

/// Robot mower drawn in code (side view, facing right), shared by the app icon, the menu bar and the sidebar.
enum MowerGlyph {
    /// Design space, y up: low shell over x 6…96 / y 28…52, wheels down to y 15, signal arcs up to y 73.
    private static func box(signal: Bool) -> CGRect { CGRect(x: 4, y: 12, width: 94, height: signal ? 63 : 42) }
    static func aspect(signal: Bool) -> CGFloat { let b = box(signal: signal); return b.width / b.height }

    static let menuBar = template(height: 9, signal: false)
    static let menuBarAlert = template(height: 9, signal: false, badge: true)
    static let sidebar = template(height: 10, signal: false)

    /// Monochrome version that macOS tints like a system symbol.
    static func template(height: CGFloat, signal: Bool = true, badge: Bool = false) -> NSImage {
        image(size: NSSize(width: (height * aspect(signal: signal)).rounded(), height: height), body: .black, wheels: .black,
              accent: nil, signal: signal, badge: badge, template: true)
    }

    static func image(size: NSSize, body: NSColor, wheels: NSColor, accent: NSColor?, signal: Bool, badge: Bool = false, template: Bool = false) -> NSImage {
        let box = box(signal: signal)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let scale = min(rect.width / box.width, rect.height / box.height)
            ctx.translateBy(x: (rect.width - box.width * scale) / 2, y: (rect.height - box.height * scale) / 2)
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -box.minX, y: -box.minY)
            draw(ctx, body: body, wheels: wheels, accent: accent, signal: signal, badge: badge, template: template)
            return true
        }
        image.isTemplate = template
        return image
    }

    private static func draw(_ ctx: CGContext, body: NSColor, wheels: NSColor, accent: NSColor?, signal: Bool, badge: Bool, template: Bool) {
        // Wheels first: the shell skirt hides their top half.
        for (center, radius) in [(CGPoint(x: 26, y: 26), CGFloat(11)), (CGPoint(x: 81, y: 22), CGFloat(7))] {
            fill(ctx, circle(center, radius), wheels)
            if template { clear(ctx, circle(center, radius * 0.4)) } else { fill(ctx, circle(center, radius * 0.4), NSColor(calibratedWhite: 0.55, alpha: 1)) }
        }
        let shell = CGMutablePath()
        shell.move(to: CGPoint(x: 12, y: 28))
        shell.addLine(to: CGPoint(x: 88, y: 28))
        shell.addCurve(to: CGPoint(x: 96, y: 35), control1: CGPoint(x: 93, y: 28), control2: CGPoint(x: 96, y: 31))
        shell.addCurve(to: CGPoint(x: 66, y: 50), control1: CGPoint(x: 96, y: 43), control2: CGPoint(x: 80, y: 49))
        shell.addLine(to: CGPoint(x: 30, y: 52))
        shell.addCurve(to: CGPoint(x: 6, y: 38), control1: CGPoint(x: 14, y: 53), control2: CGPoint(x: 6, y: 48))
        shell.addCurve(to: CGPoint(x: 12, y: 28), control1: CGPoint(x: 6, y: 31), control2: CGPoint(x: 8, y: 28))
        shell.closeSubpath()
        ctx.setBlendMode(.clear); ctx.setLineWidth(5); ctx.addPath(shell); ctx.strokePath(); ctx.setBlendMode(.normal)
        fill(ctx, shell, body)
        // Accent stripe along the shell (a cut-out in the monochrome version).
        let stripe = CGPath(roundedRect: CGRect(x: 15, y: 36, width: 72, height: 4), cornerWidth: 2, cornerHeight: 2, transform: nil)
        if let accent { fill(ctx, stripe, accent) } else { clear(ctx, stripe) }
        if signal {
            ctx.setStrokeColor(body.cgColor); ctx.setLineWidth(4.5); ctx.setLineCap(.round)
            for radius in [7.0, 14.0] as [CGFloat] {
                ctx.addArc(center: CGPoint(x: 48, y: 56), radius: radius, startAngle: .pi * 0.28, endAngle: .pi * 0.72, clockwise: false)
                ctx.strokePath()
            }
            fill(ctx, circle(CGPoint(x: 48, y: 59), 2.8), body)
        }
        if badge {
            let center = CGPoint(x: 86, y: signal ? 60 : 46)
            clear(ctx, circle(center, 13))
            fill(ctx, circle(center, 10), body)
            clear(ctx, CGPath(roundedRect: CGRect(x: center.x - 1.6, y: center.y - 1.5, width: 3.2, height: 8), cornerWidth: 1.6, cornerHeight: 1.6, transform: nil))
            clear(ctx, circle(CGPoint(x: center.x, y: center.y - 4.8), 1.8))
        }
    }
    private static func circle(_ c: CGPoint, _ r: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2), transform: nil) }
    private static func fill(_ ctx: CGContext, _ path: CGPath, _ color: NSColor) {
        ctx.setBlendMode(.normal); ctx.setFillColor(color.cgColor); ctx.addPath(path); ctx.fillPath()
    }
    private static func clear(_ ctx: CGContext, _ path: CGPath) {
        ctx.setBlendMode(.clear); ctx.addPath(path); ctx.fillPath(); ctx.setBlendMode(.normal)
    }

    /// Writes the .iconset consumed by `iconutil` (see tools/build-app.sh).
    static func writeIconset(to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for (name, pixels) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                               ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
                               ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            bitmap.size = NSSize(width: pixels, height: pixels)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            drawAppIcon(side: CGFloat(pixels))
            NSGraphicsContext.restoreGraphicsState()
            try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name + ".png"))
        }
    }
    private static func drawAppIcon(side s: CGFloat) {
        let tile = NSBezierPath(roundedRect: NSRect(x: s * 0.08, y: s * 0.08, width: s * 0.84, height: s * 0.84), xRadius: s * 0.19, yRadius: s * 0.19)
        NSGradient(starting: NSColor(calibratedRed: 0.10, green: 0.42, blue: 0.27, alpha: 1),
                   ending: NSColor(calibratedRed: 0.38, green: 0.74, blue: 0.47, alpha: 1))!.draw(in: tile, angle: 90)
        // Lawn: a darker band with blade tips, under the mower.
        NSGraphicsContext.saveGraphicsState(); tile.addClip()
        let lawn = NSBezierPath(); lawn.move(to: NSPoint(x: 0, y: 0)); lawn.line(to: NSPoint(x: 0, y: s * 0.31))
        let blades = 14
        for i in 0..<blades {
            let x0 = s * CGFloat(i) / CGFloat(blades), w = s / CGFloat(blades)
            lawn.line(to: NSPoint(x: x0 + w * 0.5, y: s * (i.isMultiple(of: 2) ? 0.355 : 0.34)))
            lawn.line(to: NSPoint(x: x0 + w, y: s * 0.31))
        }
        lawn.line(to: NSPoint(x: s, y: 0)); lawn.close()
        NSColor(calibratedRed: 0.06, green: 0.30, blue: 0.18, alpha: 1).setFill(); lawn.fill()
        NSGraphicsContext.restoreGraphicsState()
        let width = s * 0.70, height = width / aspect(signal: true)
        let glyph = image(size: NSSize(width: width, height: height), body: .white, wheels: NSColor(calibratedWhite: 0.13, alpha: 1),
                          accent: NSColor(calibratedRed: 0.98, green: 0.55, blue: 0.13, alpha: 1), signal: true)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = s * 0.025; shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012); shadow.set()
        glyph.draw(in: NSRect(x: (s - width) / 2, y: s * 0.285, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
    }
}
