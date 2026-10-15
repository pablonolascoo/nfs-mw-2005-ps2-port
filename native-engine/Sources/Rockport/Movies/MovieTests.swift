// Pruebas sin ventana de las películas:
//   Rockport --movie-test <NOMBRE|all> [--seconds N] [--lang spanish|english|…] [--size 1280x800] [--data <carpeta>] [--iso <ruta>]
// Con un nombre: reproduce la película con un reloj simulado (60 fotogramas/s, el audio marca el tiempo como en la app),
// dibuja cada imagen con el mismo MovieRenderer de la app (bandas 4:3 y subtítulos) y guarda en .build/movie-test/<NOMBRE>/:
//   frame-<s>.png cada 2 s · audio.wav (lo que sonó) · stats.json (imágenes, saltos, orden de presentación, desfase A/V).
// Con «all»: decodifica todas las películas del idioma (vídeo + audio, sin capturas) y comprueba imágenes y duraciones.
import Foundation
import Metal

enum MovieTests {
    static func handle(_ a: [String]) -> Bool {
        guard let i = a.firstIndex(of: "--movie-test") else { return false }
        let name = i + 1 < a.count && !a[i + 1].hasPrefix("-") ? a[i + 1] : "STORYFMV_BLA134"
        let dataArg = a.firstIndex(of: "--data").flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
        let (root, tried) = DataLocator.locate(arg: dataArg, disc: nil)
        guard let root else { fputs("No encuentro datos. Buscado en:\n\(tried.joined(separator: "\n"))\n", stderr); exit(1) }
        let movies = Movies.shared
        movies.log = { print($0) }
        guard let lib = movies.prepare(root: root) else { fputs("No hay movies.json en \(root.path) (convierte con tools: movies)\n", stderr); exit(1) }
        guard lib.isoAvailable else { print("Sin ISO: \(lib.isoProblem ?? "?") — la app seguiría sin películas"); exit(2) }
        let seconds = a.firstIndex(of: "--seconds").flatMap { $0 + 1 < a.count ? Double(a[$0 + 1]) : nil }
        if name.lowercased() == "all" { all(lib); return true }
        var size = (1280, 800)
        if let k = a.firstIndex(of: "--size"), k + 1 < a.count {
            let p = a[k + 1].split(separator: "x").compactMap { Int($0) }
            if p.count == 2 { size = (p[0], p[1]) }
        }
        if a.contains("--engine") { MoviePlayer.gainScale = 0; engineTest(root: root, name: name, size: size); return true }
        if a.contains("--realtime") { MoviePlayer.gainScale = a.contains("--mute") ? 0 : 1; realtime(lib, name: name, seconds: seconds ?? 8); return true }
        one(lib, name: name, seconds: seconds, size: size)
        return true
    }

    /// Una película con reloj simulado, capturas, WAV y estadísticas.
    static func one(_ lib: MovieLibrary, name: String, seconds: Double?, size: (Int, Int)) {
        guard let info = lib.info(name) else { fputs("No hay película «\(name)». Hay: \(lib.movies.keys.sorted().joined(separator: ", "))\n", stderr); exit(1) }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { fputs("sin GPU Metal\n", stderr); exit(1) }
        let out = URL(fileURLWithPath: ".build/movie-test/\(info.name)")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let t0 = CACurrentMediaTimeShim.now()
        let p = MoviePlayer(info: info, library: lib, realtime: false)
        // Carga
        while p.state == .loading && p.mpc == nil && p.error == nil { usleep(1000) }
        if let e = p.error { fputs("Error: \(e)\n", stderr); exit(1) }
        let loadMs = (CACurrentMediaTimeShim.now() - t0) * 1000
        print(String(format: "%@ · audio %@ · %d imágenes a %.0f fps · %.1f s · carga %.0f ms · subtítulos visibles: %d",
                     info.name, lib.audioLanguage(info), p.mpc?.pictures.count ?? 0, p.mpc?.fps ?? 0, p.mpc?.duration ?? 0, loadMs, p.cues.count))
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size.0, height: size.1, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]; td.storageMode = .private
        let target = device.makeTexture(descriptor: td)!
        let renderer = MovieRenderer(device: device)
        let rate = 48000, step = rate / 60
        var L = [Float](), R = [Float]()
        var l = [Float](repeating: 0, count: step), r = [Float](repeating: 0, count: step)
        let limit = min(seconds ?? .infinity, p.duration + 0.5)
        var nextShot = 0.0
        var shots: [String] = []
        var subtitlesSeen = Set<String>()
        var frames = 0
        let w0 = CACurrentMediaTimeShim.now()
        while !p.isDone {
            p.headlessWait()
            p.update()
            if p.isDone { break }
            if let s = p.subtitle { subtitlesSeen.insert(s) }
            let t = p.clock
            if t >= nextShot, p.current != nil {
                let cb = queue.makeCommandBuffer()!
                renderer.encode(cb, target: target, image: p.current?.image, subtitle: p.subtitle)
                cb.commit(); cb.waitUntilCompleted()
                let path = out.appendingPathComponent(String(format: "frame-%05.1f.png", t)).path
                writePNG(target, device: device, queue: queue, path: path)
                shots.append(path)
                nextShot += 2
            }
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in p.pullAudio(lp.baseAddress!, rp.baseAddress!, step) } }
            L += l; R += r
            frames += 1
            if t >= limit { p.finish(); break }
        }
        let wall = CACurrentMediaTimeShim.now() - w0
        SFXTests.writeWav(L, R, rate: rate, to: out.appendingPathComponent("audio.wav"))
        var st = p.stats
        st["language"] = lib.audioLanguage(info)
        st["simulatedSeconds"] = Double(frames) / 60
        st["wallSeconds"] = wall
        st["loadMs"] = loadMs
        st["subtitlesShown"] = Array(subtitlesSeen).sorted()
        st["screenshots"] = shots.count
        if let d = try? JSONSerialization.data(withJSONObject: st, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: out.appendingPathComponent("stats.json")) }
        print(String(format: "Imágenes: %d mostradas, %d saltadas, %d errores · orden de presentación %@ · A/V: audio %.2f s, vídeo %.2f s (Δ %.0f ms) · desfase medio %.1f ms, adelanto máx %.1f ms, retraso máx %.1f ms",
                     p.shown, p.skipped, p.decodeErrors, p.ptsOrderOK ? "correcto" : "MAL", p.audioDuration, p.videoDuration, (p.audioDuration - p.videoDuration) * 1000,
                     st["meanAbsOffsetMs"] as? Double ?? 0, p.maxLead * 1000, p.maxLag * 1000))
        print(String(format: "Simulado %.1f s en %.1f s (%.0f× tiempo real) · %d capturas y audio.wav en %@", Double(frames) / 60, wall, Double(frames) / 60 / max(0.001, wall), shots.count, out.path))
        if !subtitlesSeen.isEmpty { print("Subtítulos vistos (\(subtitlesSeen.count)):"); for s in subtitlesSeen.sorted().prefix(6) { print("  · " + s.replacingOccurrences(of: "\n", with: " / ")) } }
        let bad = p.decodeErrors > 0 || !p.ptsOrderOK || (seconds == nil && p.shown + p.skipped < p.videoFrames - 1)
        exit(bad ? 1 : 0)
    }

    /// Dentro del motor (sin ventana): interfaz en «Pulsa START», película en cola y `Engine.frame` en tiempo real.
    /// Comprueba que la película se queda el fotograma (captura a mitad), que el juego espera y que al acabar vuelve la interfaz.
    static func engineTest(root: URL, name: String, size: (Int, Int)) {
        guard let device = MTLCreateSystemDefaultDevice(), let data = try? GameData(root: root),
              let engine = try? Engine(device: device, data: data, outputFormat: .bgra8Unorm) else { fputs("motor: no arranca\n", stderr); exit(1) }
        let ui = engine.enableUI(outputFormat: .bgra8Unorm)
        ui?.showSplash()
        engine.aspect = Float(size.0) / Float(size.1)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size.0, height: size.1, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]; td.storageMode = .private
        let target = device.makeTexture(descriptor: td)!
        Movies.shared.prepare(root: root, language: ui?.assets.language)
        var hooks = 0
        engine.frameHooks.append { _ in hooks += 1 }
        Movies.shared.play(name) { print("Película terminada: vuelve el juego") }
        let out = URL(fileURLWithPath: ".build/movie-test/engine-\(name.uppercased())")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let t0 = CACurrentMediaTimeShim.now()
        var shot = false, framesInMovie = 0, hooksDuringMovie = 0
        var clock = 0.0
        while CACurrentMediaTimeShim.now() - t0 < 300 {
            let cb = engine.queue.makeCommandBuffer()!
            clock += 1.0 / 60
            let before = hooks
            engine.frame(cb: cb, target: target, dt: 1.0 / 60, scale: 1, now: clock)
            cb.commit(); cb.waitUntilCompleted()
            let playing = Movies.shared.isPlaying
            if playing { framesInMovie += 1; hooksDuringMovie += hooks - before }
            if !shot, let p = Movies.shared.player, p.clock > min(1.5, p.duration / 2) {
                writePNG(target, device: device, queue: engine.queue, path: out.appendingPathComponent("movie.png").path); shot = true
            }
            if !playing { break }
            usleep(16_000)
        }
        // Unos fotogramas más: la interfaz vuelve
        for _ in 0..<30 { clock += 1.0 / 60; let cb = engine.queue.makeCommandBuffer()!; engine.frame(cb: cb, target: target, dt: 1.0 / 60, scale: 1, now: clock); cb.commit(); cb.waitUntilCompleted() }
        writePNG(target, device: device, queue: engine.queue, path: out.appendingPathComponent("after.png").path)
        print(String(format: "Motor: %d fotogramas de película en %.1f s · ganchos del juego durante la película: %d · después: %d · historial: %@",
                     framesInMovie, CACurrentMediaTimeShim.now() - t0, hooksDuringMovie, hooks, Movies.shared.history.joined(separator: ", ")))
        exit(framesInMovie > 0 && hooksDuringMovie == 0 && hooks > 0 && shot ? 0 : 1)
    }

    /// En tiempo real: AVAudioEngine de verdad (con `--mute`, a volumen 0) y reloj del audio; mide el desfase de la imagen.
    static func realtime(_ lib: MovieLibrary, name: String, seconds: Double) {
        guard let info = lib.info(name) else { fputs("No hay película «\(name)»\n", stderr); exit(1) }
        let p = MoviePlayer(info: info, library: lib, realtime: true)
        let t0 = CACurrentMediaTimeShim.now()
        var lateFrames = 0
        while !p.isDone && CACurrentMediaTimeShim.now() - t0 < seconds + 2 {
            p.update()
            if p.state == .playing && p.clock >= seconds { break }
            if let c = p.current, Double(c.pts) / (p.mpc?.fps ?? 25) < p.clock - 0.08 { lateFrames += 1 }
            usleep(16_667)
        }
        let wall = CACurrentMediaTimeShim.now() - t0
        print(String(format: "%@ en tiempo real: reloj del audio %.2f s en %.2f s de pared · %d imágenes mostradas, %d saltadas · desfase medio %.1f ms (adelanto máx %.1f, retraso máx %.1f) · fotogramas con imagen > 80 ms tarde: %d",
                     info.name, p.clock, wall, p.shown, p.skipped, (p.stats["meanAbsOffsetMs"] as? Double) ?? 0, p.maxLead * 1000, p.maxLag * 1000, lateFrames))
        p.finish()
        exit(p.shown > 0 && p.maxLag < 0.1 ? 0 : 1)
    }

    /// Todas: decodifica vídeo (orden de salida de VideoToolbox incluido) y audio de cada película en el idioma elegido.
    static func all(_ lib: MovieLibrary) {
        var bad = 0, totalFrames = 0, totalSec = 0.0
        let t0 = CACurrentMediaTimeShim.now()
        for name in lib.movies.keys.sorted() {
            guard let info = lib.info(name) else { continue }
            do {
                let m = try lib.open(info)
                let a = m.decodeAudio()
                let dec = try MPEG2Decoder(m)
                dec.recordOrder = true
                var n = 0, last = -1, order = true
                while let f = dec.nextFrame() { if f.pts <= last { order = false }; last = f.pts; n += 1 }
                let aSec = Double(a.first?.count ?? 0) / Double(m.sampleRate)
                let reordered = dec.outputOrder.prefix(8).map(String.init).joined(separator: ",")
                let ok = n == m.pictures.count && dec.decodeErrors == 0 && order && abs(aSec - m.duration) < 1.5
                if !ok { bad += 1 }
                totalFrames += n; totalSec += m.duration
                print(String(format: "%@ %-22@ %@ · %4d/%4d imágenes · vídeo %6.2f s · audio %6.2f s (%d ch, %d Hz) · salida VT %@…",
                             ok ? "✓" : "✗", info.name, lib.audioLanguage(info), n, m.pictures.count, m.duration, aSec, a.count, m.sampleRate, reordered))
            } catch {
                bad += 1; print("✗ \(info.name): \(error.localizedDescription)")
            }
        }
        let w = CACurrentMediaTimeShim.now() - t0
        print("Películas de las pruebas (gameplay.json IntroMovie / OutroMovie):")
        for r in lib.raceMovieTable() { print("  \(r.event): entrada \(r.intro ?? "—") · salida \(r.outro ?? "—")") }
        print(String(format: "%d películas · %d imágenes (%.0f s de vídeo) en %.1f s (%.0f imágenes/s) · %d con problemas", lib.movies.count, totalFrames, totalSec, w, Double(totalFrames) / max(0.001, w), bad))
        exit(bad == 0 ? 0 : 1)
    }
}
