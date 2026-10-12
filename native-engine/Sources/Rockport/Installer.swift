// Instalador de primer arranque: pide la ISO del jugador, detecta el disco (PAL SLES-53559 / NTSC-U SLUS-21351)
// leyendo SYSTEM.CNF del propio ISO9660 y ejecuta el conversor que va dentro de la app
// (Contents/Resources/rockport-convert, compilado con `bun build --compile`) para escribir los datos en
// ~/Library/Application Support/Rockport/<ID>/. No se copia ni se modifica la ISO.
import AppKit

/// Discos conocidos. Otros se permiten con aviso (mismo motor, sin probar).
enum KnownDisc: String {
    case pal = "SLES-53559", ntscU = "SLUS-21351"
    var label: String {
        switch self {
        case .pal: return "PAL · SLES-53559"
        case .ntscU: return "NTSC-U · SLUS-21351 (Black Edition)"
        }
    }
}

enum DiscProbe {
    struct Result { let id: String; let known: KnownDisc? }

    /// Lee el ID del disco desde SYSTEM.CNF (BOOT2 = cdrom0:\SLES_535.59;1 → SLES-53559). [V con las dos ISOs]
    static func probe(_ url: URL) -> Result? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        func read(_ off: UInt64, _ n: Int) -> Data? { try? fh.seek(toOffset: off); return try? fh.read(upToCount: n) }
        // Descriptor de volumen primario en el sector 16; registro del directorio raíz en el byte 156.
        guard let pvd = read(16 * 2048, 2048), pvd.count == 2048, pvd[1] == 0x43, pvd[2] == 0x44 else { return nil } // "CD001"
        let u32 = { (d: Data, o: Int) -> UInt32 in d.subdata(in: o..<o + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
        let rootLBA = u32(pvd, 156 + 2), rootSize = u32(pvd, 156 + 10)
        guard let dir = read(UInt64(rootLBA) * 2048, Int(min(rootSize, 64 * 2048))) else { return nil }
        var i = 0
        while i < dir.count {
            let len = Int(dir[i])
            if len == 0 { i = (i / 2048 + 1) * 2048; continue }            // relleno hasta el siguiente sector
            let nameLen = Int(dir[i + 32])
            let name = String(decoding: dir.subdata(in: i + 33..<i + 33 + nameLen), as: UTF8.self).uppercased()
            if name.hasPrefix("SYSTEM.CNF") {
                let lba = u32(dir, i + 2), size = u32(dir, i + 10)
                guard let cnf = read(UInt64(lba) * 2048, Int(min(size, 4096))) else { return nil }
                let text = String(decoding: cnf, as: UTF8.self)
                guard let r = text.range(of: #"cdrom0:\\([A-Z]{4})_(\d{3})\.(\d{2})"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
                let m = text[r].dropFirst("cdrom0:\\".count).uppercased()        // SLES_535.59
                let id = m.prefix(4) + "-" + m.dropFirst(5).replacingOccurrences(of: ".", with: "")
                return Result(id: String(id), known: KnownDisc(rawValue: String(id)))
            }
            i += len
        }
        return nil
    }
}

/// Ventana del instalador. Estética del HUD de Most Wanted: negro, ámbar, letras condensadas.
final class InstallerController: NSObject {
    private let window: NSWindow
    private let title = NSTextField(labelWithString: "ROCKPORT")
    private let subtitle = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let button = NSButton(title: "", target: nil, action: nil)
    private var process: Process?
    private let converter: URL
    private let destRoot: URL
    private let done: (URL) -> Void

    static let amber = NSColor(srgbRed: 1, green: 0.698, blue: 0.102, alpha: 1)
    static let fog = NSColor(srgbRed: 0.553, green: 0.58, blue: 0.514, alpha: 1)

    init(converter: URL, destRoot: URL, done: @escaping (URL) -> Void) {
        self.converter = converter; self.destRoot = destRoot; self.done = done
        let screen = NSScreen.main ?? NSScreen.screens[0]
        window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        super.init()
        window.backgroundColor = NSColor(srgbRed: 0.04, green: 0.043, blue: 0.035, alpha: 1)
        window.isOpaque = true
        let v = NSView(frame: screen.frame)
        window.contentView = v

        func condensed(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            let d = base.fontDescriptor.withSymbolicTraits(.condensed)
            return NSFont(descriptor: d, size: size) ?? base
        }
        title.font = condensed(min(160, screen.frame.width / 7), .black); title.textColor = Self.amber
        subtitle.font = condensed(28, .heavy); subtitle.textColor = .white
        subtitle.stringValue = Lang.es ? "NEED FOR SPEED: MOST WANTED · NATIVO EN MAC" : "NEED FOR SPEED: MOST WANTED · NATIVE ON MAC"
        status.font = .monospacedSystemFont(ofSize: 17, weight: .medium); status.textColor = .white
        detail.font = .monospacedSystemFont(ofSize: 13, weight: .regular); detail.textColor = Self.fog
        detail.maximumNumberOfLines = 4; detail.lineBreakMode = .byWordWrapping
        bar.style = .bar; bar.isIndeterminate = false; bar.minValue = 0; bar.maxValue = 1; bar.isHidden = true
        button.bezelStyle = .rounded; button.controlSize = .large; button.font = condensed(22, .heavy)
        button.target = self; button.action = #selector(chooseISO)
        button.title = Lang.es ? "ELEGIR MI ISO DE PS2" : "CHOOSE MY PS2 ISO"
        button.keyEquivalent = "\r"
        let quit = NSButton(title: Lang.es ? "Salir" : "Quit", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .inline; quit.keyEquivalent = "\u{1b}"

        let stack = NSStackView(views: [title, subtitle, status, bar, detail, button, quit])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.setCustomSpacing(4, after: title); stack.setCustomSpacing(48, after: subtitle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: max(48, screen.frame.width * 0.08)),
            stack.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 900),
            bar.widthAnchor.constraint(equalToConstant: 640),
            detail.widthAnchor.constraint(equalToConstant: 760),
        ])
        status.stringValue = Lang.es
            ? "Necesito tu copia del juego para construir la versión nativa."
            : "I need your copy of the game to build the native version."
        detail.stringValue = Lang.es
            ? "Discos compatibles: PAL SLES-53559 y NTSC-U SLUS-21351. La ISO no se copia ni se modifica.\nLos datos convertidos se guardan en ~/Library/Application Support/Rockport."
            : "Supported discs: PAL SLES-53559 and NTSC-U SLUS-21351. The ISO is not copied or modified.\nConverted data is saved in ~/Library/Application Support/Rockport."
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func chooseISO() {
        let panel = NSOpenPanel()
        panel.title = Lang.es ? "Elige tu ISO de NFS: Most Wanted (PS2)" : "Choose your NFS: Most Wanted (PS2) ISO"
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] r in
            guard let self, r == .OK, let url = panel.url else { return }
            self.start(iso: url)
        }
    }

    private func start(iso: URL) {
        guard let disc = DiscProbe.probe(iso) else {
            status.stringValue = Lang.es ? "Ese archivo no parece una ISO de PS2." : "That file doesn't look like a PS2 ISO."
            return
        }
        if disc.known == nil {
            let a = NSAlert()
            a.messageText = Lang.es ? "Disco no probado: \(disc.id)" : "Untested disc: \(disc.id)"
            a.informativeText = Lang.es
                ? "Solo se han probado SLES-53559 (PAL) y SLUS-21351 (NTSC-U). Puede funcionar o no."
                : "Only SLES-53559 (PAL) and SLUS-21351 (NTSC-U) are tested. It may or may not work."
            a.addButton(withTitle: Lang.es ? "Probar igualmente" : "Try anyway"); a.addButton(withTitle: Lang.es ? "Cancelar" : "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        let dest = destRoot.appendingPathComponent(disc.id)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        status.stringValue = (Lang.es ? "Disco detectado: " : "Disc detected: ") + (disc.known?.label ?? disc.id)
        button.isHidden = true
        bar.isHidden = false; bar.doubleValue = 0.02
        detail.stringValue = Lang.es ? "Convirtiendo… unos minutos. No cierres la app." : "Converting… a few minutes. Don't close the app."

        let p = Process()
        p.executableURL = converter
        p.arguments = ["install", iso.path, disc.id, dest.path]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        var buffer = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = String(decoding: h.availableData, as: UTF8.self)
            guard !chunk.isEmpty else { return }
            buffer += chunk
            while let nl = buffer.firstIndex(of: "\n") {
                let line = String(buffer[..<nl]); buffer.removeSubrange(...nl)
                DispatchQueue.main.async { self?.handle(line: line) }
            }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus == 0 && DataLocator.isDataFolder(dest) {
                    self.bar.doubleValue = 1
                    self.status.stringValue = Lang.es ? "Listo. Arrancando Rockport…" : "Done. Starting Rockport…"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.window.orderOut(nil); self.done(dest) }
                } else {
                    self.status.stringValue = Lang.es ? "La conversión ha fallado." : "Conversion failed."
                    self.detail.stringValue = (Lang.es ? "Revisa el registro en " : "See the log at ") + dest.appendingPathComponent("install.log").path
                    self.button.isHidden = false
                }
            }
        }
        do { try p.run(); process = p } catch {
            status.stringValue = (Lang.es ? "No se pudo lanzar el conversor: " : "Could not start the converter: ") + error.localizedDescription
            button.isHidden = false
        }
    }

    /// El conversor escribe líneas "PASO i/n · nombre" y "OK" / "ERROR"; el resto se muestra como detalle.
    private func handle(line: String) {
        if let r = line.range(of: #"^PASO (\d+)/(\d+) · (.*)$"#, options: .regularExpression) {
            let parts = line[r].dropFirst(5).split(separator: " ", maxSplits: 2)
            let frac = parts[0].split(separator: "/")
            if frac.count == 2, let i = Double(frac[0]), let n = Double(frac[1]) { bar.doubleValue = max(0.02, (i - 1) / n) }
            if parts.count == 3 { status.stringValue = String(parts[2]) }
        } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
            detail.stringValue = String(line.prefix(220))
        }
    }
}

enum Lang {
    static let es = (Locale.preferredLanguages.first ?? "es").hasPrefix("es")
}
