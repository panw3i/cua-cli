// Render the app icon at every size an .iconset needs: swift make_icon.swift OUT.iconset
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: an 824/1024 rounded square, centered, with a soft drop shadow.
    let inset = s * 100 / 1024
    let tile = CGRect(x: inset, y: inset * 1.15, width: s - inset * 2, height: s - inset * 2)
    let radius = tile.width * 0.225
    let path = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let background = CGGradient(colorsSpace: space, colors: [
        NSColor(red: 0.36, green: 0.72, blue: 1.0, alpha: 1).cgColor,
        NSColor(red: 0.10, green: 0.38, blue: 0.95, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    // A soft highlight in the top half.
    let glow = CGGradient(colorsSpace: space, colors: [
        NSColor.white.withAlphaComponent(0.35).cgColor, NSColor.white.withAlphaComponent(0).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: tile.midX, y: tile.maxY), startRadius: 0,
                           endCenter: CGPoint(x: tile.midX, y: tile.maxY), endRadius: tile.width * 0.75, options: [])

    // Monitor: white rounded screen with a stand.
    let screen = CGRect(x: tile.minX + tile.width * 0.17, y: tile.minY + tile.height * 0.33,
                        width: tile.width * 0.66, height: tile.height * 0.46)
    let screenPath = CGPath(roundedRect: screen, cornerWidth: screen.width * 0.08, cornerHeight: screen.width * 0.08, transform: nil)
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.96).cgColor)
    ctx.addPath(screenPath)
    ctx.fillPath()
    let inner = screen.insetBy(dx: screen.width * 0.06, dy: screen.width * 0.06)
    ctx.setFillColor(NSColor(red: 0.85, green: 0.93, blue: 1, alpha: 1).cgColor)
    ctx.addPath(CGPath(roundedRect: inner, cornerWidth: inner.width * 0.05, cornerHeight: inner.width * 0.05, transform: nil))
    ctx.fillPath()
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.96).cgColor)
    let neck = CGRect(x: screen.midX - screen.width * 0.06, y: screen.minY - tile.height * 0.08, width: screen.width * 0.12, height: tile.height * 0.08)
    ctx.fill(neck)
    let foot = CGRect(x: screen.midX - screen.width * 0.22, y: neck.minY - tile.height * 0.035, width: screen.width * 0.44, height: tile.height * 0.045)
    ctx.addPath(CGPath(roundedRect: foot, cornerWidth: foot.height / 2, cornerHeight: foot.height / 2, transform: nil))
    ctx.fillPath()

    // Click rays on the screen.
    let tip = CGPoint(x: inner.midX - inner.width * 0.02, y: inner.midY + inner.height * 0.02)
    ctx.setStrokeColor(NSColor(red: 0.12, green: 0.42, blue: 0.95, alpha: 1).cgColor)
    ctx.setLineWidth(s * 0.022)
    ctx.setLineCap(.round)
    for angle in [100.0, 135.0, 170.0] {
        let a = angle * .pi / 180
        let r1 = inner.width * 0.10, r2 = inner.width * 0.19
        ctx.move(to: CGPoint(x: tip.x + cos(a) * r1, y: tip.y + sin(a) * r1))
        ctx.addLine(to: CGPoint(x: tip.x + cos(a) * r2, y: tip.y + sin(a) * r2))
    }
    ctx.strokePath()

    // Cursor arrow, tip at `tip`, pointing up-left, with a white outline and shadow.
    let u = tile.width * 0.0042
    let arrow: [CGPoint] = [(0, 0), (0, -64), (15, -50), (26, -74), (37, -69), (26, -46), (46, -46)]
        .map { CGPoint(x: tip.x + $0.0 * u, y: tip.y + $0.1 * u) }
    let cursor = CGMutablePath()
    cursor.addLines(between: arrow)
    cursor.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.006), blur: s * 0.012, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(cursor)
    ctx.setFillColor(NSColor(red: 0.08, green: 0.33, blue: 0.9, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(cursor)
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(s * 0.009)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size)@2x.png"))
}
