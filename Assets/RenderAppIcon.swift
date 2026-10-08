import AppKit

// Production artwork uses the same native geometry as the menu-bar template.
// Rebuild: swiftc -parse-as-library Sources/Claudeway/BrandIcon.swift
//          Assets/RenderAppIcon.swift -o /tmp/render-icon
//          /tmp/render-icon Assets/AppIcon.png
@main struct RenderAppIcon {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let tile = NSBezierPath(roundedRect: NSRect(x: 76, y: 76, width: 872, height: 872), xRadius: 196, yRadius: 196)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor(calibratedRed: 0.24, green: 0.18, blue: 0.12, alpha: 0.22)
        shadow.shadowOffset = NSSize(width: 0, height: -8); shadow.shadowBlurRadius = 15; shadow.set()
        NSColor(calibratedRed: 0.92, green: 0.89, blue: 0.84, alpha: 1).setFill(); tile.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(colors: [NSColor(calibratedRed: 0.92, green: 0.89, blue: 0.84, alpha: 1),
                            NSColor(calibratedRed: 0.985, green: 0.978, blue: 0.953, alpha: 1)])!.draw(in: tile, angle: 90)
        NSColor.white.withAlphaComponent(0.75).setStroke(); tile.lineWidth = 2; tile.stroke()
        let mark = BrandIcon.mark()
        var transform = AffineTransform()
        transform.translate(x: 192, y: 832)
        transform.scale(x: 32, y: -32)
        mark.transform(using: transform)
        // Shallow relief; the contour itself remains exact and reproducible.
        NSGraphicsContext.saveGraphicsState()
        let relief = NSShadow(); relief.shadowColor = NSColor(calibratedRed: 0.40, green: 0.22, blue: 0.13, alpha: 0.24)
        relief.shadowOffset = NSSize(width: 0, height: -3); relief.shadowBlurRadius = 5; relief.set()
        NSColor(calibratedRed: 0.69, green: 0.34, blue: 0.21, alpha: 1).setFill(); mark.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(colors: [NSColor(calibratedRed: 0.68, green: 0.32, blue: 0.20, alpha: 1),
                            NSColor(calibratedRed: 0.81, green: 0.45, blue: 0.29, alpha: 1)])!.draw(in: mark, angle: 90)
        NSColor(calibratedRed: 0.88, green: 0.58, blue: 0.40, alpha: 0.6).setStroke()
        mark.lineWidth = 1.8; mark.stroke()
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
