// Icono de la app con la imagen del juego, compuesto con las texturas de TU disco (no viaja ninguna imagen de EA en el DMG):
//   fondo  = ENDGAME   (GLOBAL/GLOBALB.LZC, 512×512: el BMW M3 GTR de la portada) [V]
//   logo   = MW_LOGO   (GLOBAL/GLOBALA.BUN, 256×64: «Need for Speed Most Wanted») [V]
// Se compone en forma de icono de macOS (cuadrado redondeado 1024 px con margen), se guarda en <datos>/icon.png,
// se pone en el Dock al arrancar (NSApp.applicationIconImage) y, una vez por instalación, como icono de Rockport.app
// en el Finder, Spotlight y el Launchpad (NSWorkspace.setIcon). El icono propio del bundle (AppIcon.icns) queda debajo.
import AppKit

enum AppIcon {
    /// Busca una textura de la interfaz por su nombre del juego (frontend/index.json → textures/<hash>.png).
    private static func texture(_ name: String, root: URL) -> NSImage? {
        let fe = root.appendingPathComponent("frontend")
        guard let d = try? Data(contentsOf: fe.appendingPathComponent("index.json")),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let tex = j["textures"] as? [String: [String: Any]],
              let hash = tex.first(where: { ($0.value["name"] as? String) == name })?.key else { return nil }
        return NSImage(contentsOf: fe.appendingPathComponent("textures/\(hash).png"))
    }

    /// Compone el icono (1024×1024). nil si faltan las texturas.
    static func compose(root: URL) -> NSImage? {
        guard let art = texture("ENDGAME", root: root), let logo = texture("MW_LOGO", root: root) else { return nil }
        let size = 1024.0
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        // Rejilla de iconos de macOS: 824 px de cuadrado en 1024, radio ≈ 185, sombra suave
        let box = NSRect(x: 100, y: 100, width: 824, height: 824)
        let shape = NSBezierPath(roundedRect: box, xRadius: 185, yRadius: 185)
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.45); sh.shadowBlurRadius = 24; sh.shadowOffset = NSSize(width: 0, height: -10)
        sh.set(); NSColor.black.setFill(); shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        // El arte sin deformar: la textura es cuadrada pero el juego la pinta a 900×512 (GameWon / RapSheet*_ENDGAME,
        // tamaño del objeto FEng) [V], así que un recorte cuadrado real ocupa 512/900 de ancho por cada píxel de alto.
        // Encuadre sobre el coche (derecha-abajo de ENDGAME).
        let a = art.size, aspect = 900.0 / 512.0
        let ch = a.height * 0.94, cw = ch / aspect
        let crop = NSRect(x: min(a.width - cw, a.width * 0.725 - cw / 2), y: a.height * 0.02, width: cw, height: ch)
        art.draw(in: box, from: crop, operation: .copy, fraction: 1)
        // Tono amarillento de Most Wanted y oscurecido abajo para el logo
        NSColor(calibratedRed: 1.0, green: 0.82, blue: 0.35, alpha: 0.16).setFill()
        box.fill(using: .sourceAtop)
        NSGradient(colors: [NSColor.black.withAlphaComponent(0.92), NSColor.black.withAlphaComponent(0.55), .clear],
                   atLocations: [0, 0.22, 0.5], colorSpace: .deviceRGB)?.draw(in: box, angle: 90)
        // Logo MW (blanco con alfa) abajo, a lo ancho
        let lw = box.width * 0.80, lh = lw * logo.size.height / logo.size.width
        let lr = NSRect(x: box.midX - lw / 2, y: box.minY + 44, width: lw, height: lh)
        NSGraphicsContext.saveGraphicsState()
        let ls = NSShadow(); ls.shadowColor = .black; ls.shadowBlurRadius = 14; ls.set()
        logo.draw(in: lr, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        // Borde fino claro, como los iconos del sistema
        NSColor.white.withAlphaComponent(0.12).setStroke()
        let edge = NSBezierPath(roundedRect: box.insetBy(dx: 1.5, dy: 1.5), xRadius: 184, yRadius: 184); edge.lineWidth = 3; edge.stroke()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: NSSize(width: size, height: size))
        img.addRepresentation(rep)
        return img
    }

    /// Dock ya; Finder/Spotlight una vez por instalación de datos (marca en <datos>/icon.png).
    static func apply(root: URL) {
        let png = root.appendingPathComponent("icon.png")
        var img = NSImage(contentsOf: png)
        if img == nil, let c = compose(root: root) {
            img = c
            if let tiff = c.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let d = rep.representation(using: .png, properties: [:]) {
                try? d.write(to: png)
            }
        }
        guard let img else { return }
        NSApp.applicationIconImage = img
        // Icono del bundle en el Finder (solo si es una app instalada, no el binario de swift build)
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app", FileManager.default.isWritableFile(atPath: app.path) else { return }
        let mark = root.appendingPathComponent("icon.applied")
        let stamp = app.path + "|" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
        if (try? String(contentsOf: mark, encoding: .utf8)) == stamp { return }
        if NSWorkspace.shared.setIcon(img, forFile: app.path, options: []) {
            try? stamp.write(to: mark, atomically: true, encoding: .utf8)
            NSWorkspace.shared.noteFileSystemChanged(app.path)
        }
    }

    /// --make-icon <datos> <salida.png>: compone el icono sin abrir el juego (pruebas y capturas).
    static func runCLI() -> Bool {
        let args = CommandLine.arguments
        guard let k = args.firstIndex(of: "--make-icon"), k + 2 < args.count else { return false }
        guard let img = compose(root: URL(fileURLWithPath: args[k + 1])), let tiff = img.tiffRepresentation,
              let d = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            fputs("No encuentro ENDGAME / MW_LOGO en \(args[k + 1])/frontend\n", stderr); exit(1)
        }
        try? d.write(to: URL(fileURLWithPath: args[k + 2])); print("Icono: \(args[k + 2])")
        return true
    }
}
