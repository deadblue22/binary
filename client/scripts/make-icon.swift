// Renders the Binary app icon into an .iconset directory.
// Usage: swift scripts/make-icon.swift <out.iconset>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let rect = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s)

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 24 * s
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGradient(colors: [NSColor(red: 0.16, green: 0.15, blue: 0.24, alpha: 1),
                        NSColor(red: 0.06, green: 0.06, blue: 0.09, alpha: 1)])!
        .draw(in: shape, angle: -90)

    // Two stacked "sessions": a 0 and a 1 in a terminal-like monospace.
    let font = NSFont.monospacedSystemFont(ofSize: 380 * s, weight: .heavy)
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let text = NSAttributedString(string: "01", attributes: [
        .font: font,
        .foregroundColor: NSColor(red: 0.96, green: 0.94, blue: 0.90, alpha: 1),
        .paragraphStyle: para,
        .kern: -20 * s,
    ])
    let size = text.size()
    text.draw(in: NSRect(x: rect.minX, y: rect.midY - size.height / 2 + 20 * s, width: rect.width, height: size.height))

    // Status dot, the color the app uses for "running".
    let dot = NSRect(x: rect.maxX - 190 * s, y: rect.maxY - 190 * s, width: 90 * s, height: 90 * s)
    NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1).setFill()
    NSBezierPath(ovalIn: dot).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
