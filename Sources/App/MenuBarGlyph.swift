import AppKit

/// The menu bar icon: the app icon's three stacked screens as a one-colour
/// template, so macOS tints it for light, dark and highlighted menu bars.
///
/// The front screen is filled while the Mac is staying awake with the lid
/// closed and outlined otherwise — the state the old laptop/moon symbols
/// showed, in the same glyph.
enum MenuBarGlyph {

    static func image(armed: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let line: CGFloat = 1.3
            // Back to front. Each pane first clears what it covers, so the
            // panes behind show only where they peek out.
            let panes = [NSRect(x: 1.2, y: 2.0, width: 10.5, height: 7.2),
                         NSRect(x: 3.8, y: 4.8, width: 10.5, height: 7.2),
                         NSRect(x: 6.4, y: 7.6, width: 10.5, height: 7.2)]
            for (index, pane) in panes.enumerated() {
                let path = NSBezierPath(roundedRect: pane, xRadius: 1.8, yRadius: 1.8)
                NSGraphicsContext.current?.compositingOperation = .clear
                path.fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSColor.black.set()
                if index == panes.count - 1, armed {
                    path.fill()
                } else {
                    let inset = NSBezierPath(roundedRect: pane.insetBy(dx: line / 2, dy: line / 2),
                                             xRadius: 1.8 - line / 2, yRadius: 1.8 - line / 2)
                    inset.lineWidth = line
                    inset.stroke()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = armed ? "Staying awake with the lid closed" : "Normal sleep"
        return image
    }
}
