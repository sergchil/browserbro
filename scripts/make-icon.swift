// Renders the app icon (1024×1024 PNG) with AppKit. Usage: swift scripts/make-icon.swift <out.png>
import AppKit

let size = 1024.0
let out = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    // macOS icon grid: 824×824 body with ~185 pt corner radius, centered.
    let body = rect.insetBy(dx: 100, dy: 100)
    let path = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // Glass-like top sheen.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0.0)])?
        .draw(in: path, angle: -90)

    // The notch at the top edge.
    let notch = NSBezierPath(roundedRect: NSRect(x: body.midX - 150, y: body.maxY - 70, width: 300, height: 110), xRadius: 40, yRadius: 40)
    NSColor(white: 0.16, alpha: 1).setFill()
    notch.fill()

    // Branching arrow symbol, tinted with a blue → purple gradient.
    let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let s = symbol.size
        let target = NSRect(x: body.midX - s.width / 2, y: body.midY - s.height / 2 - 30, width: s.width, height: s.height)
        let tinted = NSImage(size: s, flipped: false) { r in
            symbol.draw(in: r)
            NSGraphicsContext.current?.compositingOperation = .sourceIn
            NSGradient(colors: [NSColor.systemTeal, NSColor.systemBlue, NSColor.systemPurple])?.draw(in: r, angle: -60)
            return true
        }
        tinted.draw(in: target)
    }
    return true
}
guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("render failed") }
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
