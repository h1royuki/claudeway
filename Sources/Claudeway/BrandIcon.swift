import AppKit

/// "Shift": six broad ray terminals, four silhouettes and an open diagonal seam.
/// Drawn natively instead of shrinking the textured application-icon bitmap.
enum BrandIcon {
    static func mark() -> NSBezierPath {
        let mark = NSBezierPath()
        let joined = NSBezierPath()
        joined.move(to: NSPoint(x: 7.6, y: 0.6))
        joined.line(to: NSPoint(x: 11.2, y: 0.6))
        joined.curve(to: NSPoint(x: 12.1, y: 1.6), controlPoint1: NSPoint(x: 11.9, y: 0.6), controlPoint2: NSPoint(x: 12.3, y: 1.0))
        joined.line(to: NSPoint(x: 11.4, y: 6.2))
        joined.curve(to: NSPoint(x: 10.9, y: 7.0), controlPoint1: NSPoint(x: 11.35, y: 6.6), controlPoint2: NSPoint(x: 11.15, y: 6.85))
        joined.line(to: NSPoint(x: 6.9, y: 9.7))
        joined.curve(to: NSPoint(x: 6.25, y: 9.8), controlPoint1: NSPoint(x: 6.7, y: 9.85), controlPoint2: NSPoint(x: 6.5, y: 9.85))
        joined.line(to: NSPoint(x: 1.0, y: 8.45))
        joined.curve(to: NSPoint(x: 0.55, y: 7.05), controlPoint1: NSPoint(x: 0.35, y: 8.3), controlPoint2: NSPoint(x: 0.15, y: 7.65))
        joined.line(to: NSPoint(x: 2.45, y: 4.4))
        joined.curve(to: NSPoint(x: 3.75, y: 4.2), controlPoint1: NSPoint(x: 2.8, y: 3.9), controlPoint2: NSPoint(x: 3.3, y: 3.85))
        joined.line(to: NSPoint(x: 7.4, y: 7.15))
        joined.curve(to: NSPoint(x: 7.8, y: 6.9), controlPoint1: NSPoint(x: 7.65, y: 7.35), controlPoint2: NSPoint(x: 7.9, y: 7.15))
        joined.line(to: NSPoint(x: 6.75, y: 1.75))
        joined.curve(to: NSPoint(x: 7.6, y: 0.6), controlPoint1: NSPoint(x: 6.6, y: 1.05), controlPoint2: NSPoint(x: 6.95, y: 0.6))
        joined.close()

        let wedge = NSBezierPath()
        wedge.move(to: NSPoint(x: 11.3, y: 9.65))
        wedge.line(to: NSPoint(x: 16.05, y: 4.4))
        wedge.curve(to: NSPoint(x: 17.4, y: 4.5), controlPoint1: NSPoint(x: 16.5, y: 3.9), controlPoint2: NSPoint(x: 17.0, y: 4.0))
        wedge.line(to: NSPoint(x: 19.3, y: 7.1))
        wedge.curve(to: NSPoint(x: 18.9, y: 8.45), controlPoint1: NSPoint(x: 19.8, y: 7.75), controlPoint2: NSPoint(x: 19.6, y: 8.25))
        wedge.line(to: NSPoint(x: 11.6, y: 10.2))
        wedge.curve(to: NSPoint(x: 11.3, y: 9.65), controlPoint1: NSPoint(x: 11.1, y: 10.35), controlPoint2: NSPoint(x: 10.95, y: 10.05))
        wedge.close()
        mark.append(joined); mark.append(wedge)
        var halfTurn = AffineTransform()
        halfTurn.translate(x: 20, y: 20)
        halfTurn.rotate(byDegrees: 180)
        joined.transform(using: halfTurn); wedge.transform(using: halfTurn)
        mark.append(joined); mark.append(wedge)
        return mark
    }

    static func menuBar() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setFill()
            let path = mark()
            var fit = AffineTransform()
            // A 16pt optical mark inside an 18pt template, rather than a dense
            // edge-to-edge symbol beside macOS's lighter menu-bar glyphs.
            fit.translate(x: 1, y: 1)
            fit.scale(0.8)
            path.transform(using: fit)
            path.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Claudeway"
        return image
    }
}
