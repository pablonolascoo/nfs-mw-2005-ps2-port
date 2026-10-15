// Icono propio de Rockport.app (sin material de EA): asfalto de noche, líneas amarillas en perspectiva y una «R».
// Es el que se ve en el DMG y antes de instalar el disco; después la app pone el del juego (Sources/Rockport/AppIcon.swift).
// Uso: swift scripts/app-icon.swift <carpeta.iconset>
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px), k = s / 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let box = NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let shape = NSBezierPath(roundedRect: box, xRadius: 185 * k, yRadius: 185 * k)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.45); sh.shadowBlurRadius = 24 * k; sh.shadowOffset = NSSize(width: 0, height: -10 * k)
    sh.set(); NSColor.black.setFill(); shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    shape.addClip()
    NSGradient(colors: [NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.04, alpha: 1), NSColor(calibratedRed: 0.20, green: 0.17, blue: 0.09, alpha: 1)])?.draw(in: box, angle: 90)
    // Carretera en perspectiva hacia el horizonte
    let hz = box.minY + box.height * 0.62, cx = box.midX
    let road = NSBezierPath()
    road.move(to: NSPoint(x: box.minX - 80 * k, y: box.minY)); road.line(to: NSPoint(x: cx - 18 * k, y: hz))
    road.line(to: NSPoint(x: cx + 18 * k, y: hz)); road.line(to: NSPoint(x: box.maxX + 80 * k, y: box.minY)); road.close()
    NSColor(calibratedRed: 0.10, green: 0.09, blue: 0.07, alpha: 1).setFill(); road.fill()
    let amber = NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.18, alpha: 1)
    amber.setFill()
    for (a, b) in [(0.00, 0.16), (0.24, 0.36), (0.44, 0.52), (0.60, 0.65), (0.72, 0.75)] {   // discontinua central
        let y0 = box.minY + (hz - box.minY) * CGFloat(a), y1 = box.minY + (hz - box.minY) * CGFloat(b)
        let w0 = 22 * k * (1 - CGFloat(a)) + 2 * k, w1 = 22 * k * (1 - CGFloat(b)) + 2 * k
        let p = NSBezierPath(); p.move(to: NSPoint(x: cx - w0, y: y0)); p.line(to: NSPoint(x: cx + w0, y: y0))
        p.line(to: NSPoint(x: cx + w1, y: y1)); p.line(to: NSPoint(x: cx - w1, y: y1)); p.close(); p.fill()
    }
    // Sol bajo y amarillento en el horizonte
    NSGradient(colors: [amber.withAlphaComponent(0.6), amber.withAlphaComponent(0.15), amber.withAlphaComponent(0)], atLocations: [0, 0.5, 1], colorSpace: .deviceRGB)?
        .draw(fromCenter: NSPoint(x: cx, y: hz), radius: 0, toCenter: NSPoint(x: cx, y: hz), radius: 360 * k, options: [])
    // «R»
    let font = NSFont(name: "Futura-CondensedExtraBold", size: 470 * k) ?? NSFont.systemFont(ofSize: 470 * k, weight: .black)
    let para = NSMutableParagraphStyle(); para.alignment = .center
    let sh2 = NSShadow(); sh2.shadowColor = NSColor.black.withAlphaComponent(0.8); sh2.shadowBlurRadius = 30 * k
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(calibratedWhite: 0.96, alpha: 1), .paragraphStyle: para,
                                               .obliqueness: 0.18, .shadow: sh2]
    NSAttributedString(string: "R", attributes: attrs).draw(in: NSRect(x: box.minX, y: box.minY + 250 * k, width: box.width, height: 560 * k))
    NSColor.white.withAlphaComponent(0.12).setStroke()
    let edge = NSBezierPath(roundedRect: box.insetBy(dx: 1.5 * k, dy: 1.5 * k), xRadius: 184 * k, yRadius: 184 * k); edge.lineWidth = 3 * k; edge.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
