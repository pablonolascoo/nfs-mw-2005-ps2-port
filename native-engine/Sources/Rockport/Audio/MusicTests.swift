// Prueba sin ventana de la música:
//   Rockport --music-test [--seconds N] [--project 1…4] [--data <carpeta>]
// Simula zona libre (canción de EA Trax) → persecución (cerca de la policía, huida rápida, enfriamiento, escondido) →
// evasión → ambiente de la zona → canción, con la lógica de MusicFlow y el grafo PathFinder; mezcla a 32 kHz sin tiempo real.
// Salida en .build/music-test/: music.wav (lo que sonó), log.txt (cambios de tipo, estados, eventos, ondas y ramas) y un
// resumen por consola.
import Foundation
import simd

enum MusicTests {
    /// `--music-live S [--music-volume V]`: la música de la zona libre por la salida real (AVAudioEngine) durante S segundos.
    static func live(_ a: [String], seconds: Double) {
        let dataArg = a.firstIndex(of: "--data").flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
        let (root, _) = DataLocator.locate(arg: dataArg, disc: nil)
        let ms = MusicSystem.shared
        guard let root, ms.prepare(root: root), let out = ms.output else { fputs("sin música\n", stderr); exit(1) }
        out.start()
        var w = MusicWorld(); w.place = .game; w.carPosition = float2(1660, 2410)
        ms.world = w
        let t0 = CACurrentMediaTimeShim.now()
        var peak: Float = 0
        while CACurrentMediaTimeShim.now() - t0 < seconds { ms.tick(); peak = max(peak, out.peak); usleep(16_667) }
        print(String(format: "Música en tiempo real %.0f s: salida %@ · %@ · pico %.3f", seconds, out.isRunning ? "en marcha" : "PARADA", ms.currentSong.map { "\($0.artist) – \($0.title)" } ?? "—", peak))
        exit(out.isRunning ? 0 : 1)
    }

    static func handle(_ a: [String]) -> Bool {
        if let i = a.firstIndex(of: "--music-live") { live(a, seconds: i + 1 < a.count ? Double(a[i + 1]) ?? 5 : 5); return true }
        guard a.contains("--music-test") else { return false }
        let dataArg = a.firstIndex(of: "--data").flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
        let (root, tried) = DataLocator.locate(arg: dataArg, disc: nil)
        guard let root else { fputs("No encuentro datos. Buscado en:\n\(tried.joined(separator: "\n"))\n", stderr); exit(1) }
        let total = a.firstIndex(of: "--seconds").flatMap { $0 + 1 < a.count ? Double(a[$0 + 1]) : nil } ?? 175
        let ms = MusicSystem.shared
        MusicTrack.synchronousDecode = true
        guard ms.prepare(root: root), let out = ms.output else { fputs("No hay music/ en \(root.path)\n", stderr); exit(1) }
        if let i = a.firstIndex(of: "--project"), i + 1 < a.count, let p = Int(a[i + 1]) { ms.setInteractiveProject(p - 1) }
        var settings = ms.settings
        settings.volume = 0.8
        _ = settings
        let dir = URL(fileURLWithPath: ".build/music-test")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var log: [String] = []
        var t = 0.0
        func note(_ s: String) { let line = String(format: "%7.2f s  %@", t, s); log.append(line) }
        ms.setTrace { note($0) }

        // Guion: posición en la zona libre (refugio 1) y persecución por tramos
        var w = MusicWorld()
        w.place = .game
        w.carPosition = float2(1660, 2410)
        w.topSpeedMPH = 180
        struct Phase { let from: Double; let name: String; let f: (inout MusicWorld, Double) -> Void }
        let busted: [Phase] = [
            Phase(from: 0, name: "zona libre a 60 mph") { w, _ in w.pursuit = .inactive; w.playerSpeedMPH = 60 },
            Phase(from: 15, name: "persecución: la policía pegada (15–25 m)") { w, _ in w.pursuit = .active; w.playerSpeedMPH = 70; w.pursuitDistance = 18 },
            Phase(from: 70, name: "encerrado: parado, la policía encima") { w, s in w.pursuit = .active; w.playerSpeedMPH = 2; w.pursuitDistance = 4; w.collapseActive = true; w.highIntensity = true; w.timeUntilBusted = Float(max(0, 5 - s)) },
            Phase(from: 75, name: "arrestado") { w, _ in w.pursuit = .inactive; w.busted = true; w.collapseActive = false; w.playerSpeedMPH = 0; w.pursuitDistance = -1 },
            Phase(from: 80, name: "de vuelta en la zona libre") { w, _ in w.busted = false; w.playerSpeedMPH = 30 },
        ]
        let chase: [Phase] = [
            Phase(from: 0, name: "zona libre a 60 mph") { w, _ in w.pursuit = .inactive; w.playerSpeedMPH = 60 },
            Phase(from: 15, name: "persecución: la policía pegada (15–25 m)") { w, _ in w.pursuit = .active; w.playerSpeedMPH = 70; w.pursuitDistance = 18; w.perpLostTime = 0 },
            Phase(from: 60, name: "huida a 150 mph, policía a 90 m") { w, _ in w.pursuit = .active; w.playerSpeedMPH = 150; w.pursuitDistance = 90; w.perpLostTime = 0 },
            Phase(from: 95, name: "enfriamiento, aún rápido") { w, s in w.pursuit = .searching; w.cooldown = true; w.playerSpeedMPH = 120; w.pursuitDistance = -1; w.perpLostTime = Float(s) },
            Phase(from: 105, name: "escondido y parado") { w, s in w.pursuit = .searching; w.cooldown = true; w.playerSpeedMPH = 0; w.pursuitDistance = -1; w.perpLostTime = Float(10 + s) },
            Phase(from: 120, name: "evadido: fin de la persecución") { w, _ in w.pursuit = .inactive; w.cooldown = false; w.playerSpeedMPH = 40; w.pursuitDistance = -1 },
        ]
        let phases = a.contains("--busted") ? busted : chase
        let rate = Int(out.rate)
        var L = [Float](), R = [Float]()
        L.reserveCapacity(Int(total) * rate); R.reserveCapacity(Int(total) * rate)
        var l = [Float](repeating: 0, count: 1024), r = [Float](repeating: 0, count: 1024)
        var frac = 0.0
        var current = -1
        var stateTime: [String: Double] = [:]
        var typeTime: [String: Double] = [:]
        let w0 = CACurrentMediaTimeShim.now()
        var maxStep = 0.0
        let usedProject = ms.interactiveTrack?.project.name ?? "—"
        while t < total {
            let k = phases.lastIndex { $0.from <= t } ?? 0
            if k != current { current = k; note("— \(phases[k].name)") }
            phases[k].f(&w, t - phases[k].from)
            ms.world = w
            let s0 = CACurrentMediaTimeShim.now()
            ms.step(dt: 1.0 / 60)
            maxStep = max(maxStep, CACurrentMediaTimeShim.now() - s0)
            stateTime[ms.flow.state.rawValue, default: 0] += 1.0 / 60
            typeTime[ms.type.rawValue, default: 0] += 1.0 / 60
            frac += Double(rate) / 60
            let n = Int(frac); frac -= Double(n)
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in out.render(lp.baseAddress!, rp.baseAddress!, n) } }
            L += l[0..<n]; R += r[0..<n]
            t += 1.0 / 60
        }
        let wall = CACurrentMediaTimeShim.now() - w0
        SFXTests.writeWav(L, R, rate: rate, to: dir.appendingPathComponent("music.wav"))
        try? log.joined(separator: "\n").write(to: dir.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
        // Resumen
        let waves = log.filter { $0.contains(": onda ") }.count
        let routers = log.filter { $0.contains("router") }
        let events = log.filter { $0.contains("MusicFlow → evento") }
        var rms = 0.0, peak: Float = 0
        for i in stride(from: 0, to: L.count, by: 16) { rms += Double(L[i] * L[i]); peak = max(peak, abs(L[i])) }
        rms = (rms / Double(max(1, L.count / 16))).squareRoot()
        print("Música · proyecto de persecución \(usedProject) · \(String(format: "%.0f s simulados en %.1f s (paso máx. %.1f ms)", total, wall, maxStep * 1000))")
        for line in log where !line.contains(": onda ") && !line.contains("evento ") || line.contains("MusicFlow → evento") || line.contains("router") { print(line) }
        print(String(format: "Ondas encoladas: %d · eventos de MusicFlow: %d · routers: %d · RMS %.3f, pico %.3f", waves, events.count, routers.count, rms, peak))
        print("Tiempo por tipo: " + typeTime.sorted { $0.key < $1.key }.map { String(format: "%@ %.0f s", $0.key, $0.value) }.joined(separator: " · "))
        print("Tiempo por estado de MusicFlow: " + stateTime.sorted { $0.key < $1.key }.map { String(format: "%@ %.0f s", $0.key, $0.value) }.joined(separator: " · "))
        print("Salida: \(dir.path)/music.wav y log.txt (\(log.count) líneas)")
        let ok = events.count >= 2 && typeTime["interactive", default: 0] > 30 && rms > 0.005
        exit(ok ? 0 : 1)
    }
}
