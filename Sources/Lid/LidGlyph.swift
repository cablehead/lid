import AppKit

/// The menu bar icon: a closed laptop under a sun, like the app icon.
/// The sun is outlined while the Mac sleeps as macOS would when the lid
/// shuts, and filled while Lid keeps it awake.
enum LidGlyph {
    static func image(filled: Bool, label: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            draw(filled: filled)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = label
        return image
    }

    static func draw(filled: Bool) {
        NSColor.black.set()

        let sun = NSBezierPath(ovalIn: NSRect(x: 6.4, y: 3.4, width: 5.2, height: 5.2))
        sun.lineWidth = 1.2
        if filled { sun.fill() }
        sun.stroke()

        let rays = NSBezierPath()
        for (from, to) in [((9.0, 1.2), (9.0, 2.1)), ((4.3, 6.0), (5.2, 6.0)), ((12.8, 6.0), (13.7, 6.0)),
                           ((5.7, 2.7), (6.3, 3.3)), ((12.3, 2.7), (11.7, 3.3))] {
            rays.move(to: NSPoint(x: from.0, y: from.1))
            rays.line(to: NSPoint(x: to.0, y: to.1))
        }
        rays.lineWidth = 1.1
        rays.lineCapStyle = .round
        rays.stroke()

        let lid = NSBezierPath(roundedRect: NSRect(x: 3, y: 11, width: 12, height: 2.4), xRadius: 0.8, yRadius: 0.8)
        lid.lineWidth = 1.2
        lid.stroke()

        let base = NSBezierPath()
        base.move(to: NSPoint(x: 1.8, y: 15.4))
        base.line(to: NSPoint(x: 16.2, y: 15.4))
        base.lineWidth = 1.3
        base.lineCapStyle = .round
        base.stroke()
    }
}
