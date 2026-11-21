import AppKit

/// The menu bar icon: a scallop shell. Outlined, the Mac sleeps as macOS
/// would when the lid shuts; filled, Lid is keeping it awake.
enum ClamGlyph {
    static func image(filled: Bool, label: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            draw(filled: filled)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = label
        return image
    }

    private static let center = NSPoint(x: 9, y: 14.2)
    private static let ribs = 5

    /// Points along the fan's top edge, left to right.
    private static func edge(_ i: Int, of n: Int, out: CGFloat = 1) -> NSPoint {
        let from = 205.0, to = 335.0
        let a = (from + (to - from) * Double(i) / Double(n)) * .pi / 180
        return NSPoint(x: center.x + 7.3 * out * CGFloat(cos(a)), y: center.y + 10.6 * out * CGFloat(sin(a)))
    }

    static func draw(filled: Bool) {
        NSColor.black.set()
        // One outline: the hinge's small wings at the base, then the fan.
        let shell = NSBezierPath()
        shell.move(to: NSPoint(x: 5.2, y: 16.4))
        shell.line(to: NSPoint(x: 5.2, y: center.y))
        shell.line(to: NSPoint(x: 7.4, y: center.y))
        shell.line(to: edge(0, of: ribs))
        for i in 0..<ribs {
            // Each rib ends in a bump that rises above the fan's outline.
            let mid = edge(2 * i + 1, of: 2 * ribs, out: 1.13)
            shell.curve(to: edge(i + 1, of: ribs), controlPoint1: mid, controlPoint2: mid)
        }
        shell.line(to: NSPoint(x: 10.6, y: center.y))
        shell.line(to: NSPoint(x: 12.8, y: center.y))
        shell.line(to: NSPoint(x: 12.8, y: 16.4))
        shell.close()
        shell.lineJoinStyle = .round
        shell.lineWidth = 1.2

        let grooves = NSBezierPath()
        for i in 1..<ribs {
            let tip = edge(i, of: ribs, out: 0.9)
            grooves.move(to: NSPoint(x: center.x + (tip.x - center.x) * 0.2, y: center.y - 1))
            grooves.line(to: tip)
        }
        grooves.lineCapStyle = .round

        if filled {
            shell.fill()
            // Grooves are cut out of the fill.
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            grooves.lineWidth = 1.0
            grooves.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        } else {
            shell.stroke()
            grooves.lineWidth = 0.9
            grooves.stroke()
        }
    }
}
