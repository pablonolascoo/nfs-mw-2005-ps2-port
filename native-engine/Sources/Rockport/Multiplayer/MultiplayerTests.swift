// Pruebas sin ventana de la pantalla partida y de la carrera rápida.
//
//   Rockport --split-test N [--seconds S] [--race ID] [--opponents K] [--displays D] [--size AxB] [--screenshot base.png]
//       N jugadores (1…4) con piloto automático en la prueba ID (15.1.1 por defecto). D pantallas falsas (texturas aparte del
//       mismo tamaño). Capturas -start / -mid / -end por pantalla y tiempos de GPU y CPU por fotograma (todas las pantallas).
//   Rockport --quickrace-test [--split N] [--screenshot base.png]
//       Recorre las pantallas de la carrera rápida como un jugador (UI/QuickRaceFlow.swift) y saca una captura de cada una.
import Foundation
import Metal
import QuartzCore
import simd

enum MPTestOptions {
    static var args: [String] { CommandLine.arguments }
    static func value(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    static var splitTest: Int? { value("--split-test").flatMap(Int.init) }
    static var quickRaceTest: Bool { args.contains("--quickrace-test") }
}

func makeMPTestEngine(_ o: Options) -> (MTLDevice, Engine) {
    guard let device = MTLCreateSystemDefaultDevice() else { fputs("sin GPU Metal\n", stderr); exit(1) }
    let (root, tried) = DataLocator.locate(arg: o.data, disc: o.disc)
    guard let root, let data = try? GameData(root: root) else { fputs("No encuentro datos. Buscado en:\n\(tried.joined(separator: "\n"))\n", stderr); exit(1) }
    do { return (device, try Engine(device: device, data: data, outputFormat: .bgra8Unorm)) } catch { fputs("motor: \(error)\n", stderr); exit(1) }
}

func makeTarget(_ device: MTLDevice, _ w: Int, _ h: Int) -> MTLTexture {
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
    td.usage = [.renderTarget, .shaderRead]; td.storageMode = .private
    return device.makeTexture(descriptor: td)!
}

/// Espera a que carguen las casillas alrededor de las cámaras (simulación parada).
func waitForStreaming(_ engine: Engine, step: () -> Void) {
    let l0 = CACurrentMediaTime()
    var frames = 0
    while true {
        step(); frames += 1
        let s = engine.streamer.stats
        if engine.streamer.allFarLoaded && engine.streamer.idle && s.nearReady == s.near && frames > 30 { break }
        if CACurrentMediaTime() - l0 > 120 { fputs("aviso: carga agotada\n", stderr); break }
        usleep(5000)
    }
}

func runSplitTest(_ o: Options, players n: Int) {
    let n = max(1, min(4, n))
    let (device, engine) = makeMPTestEngine(o)
    if let g = o.grade { engine.renderer.gradeStrength = g }
    _ = engine.enableUI(outputFormat: .bgra8Unorm)
    guard let sys = engine.enableRaces() else { fputs("Carreras no disponibles (falta races.json)\n", stderr); exit(1) }
    Career.shared.persist = false
    let key = RaceTestOptions.value("--race") ?? "15.1.1"
    guard let event = sys.db.event(key) else { fputs("No existe la prueba «\(key)»\n", stderr); exit(1) }
    let displays = max(1, min(n, MPTestOptions.value("--displays").flatMap(Int.init) ?? 1))
    let (W, H) = o.size
    engine.aspect = Float(W) / Float(H)
    let targets = (0..<displays).map { _ in makeTarget(device, W, H) }
    if let ai = engine.ai { let t0 = CACurrentMediaTime(); while !ai.models.allIdle && CACurrentMediaTime() - t0 < 60 { usleep(20000) } }

    // Coches: el de la historia y la Lista Negra; dispositivo: el teclado (los lleva el piloto automático)
    let ids = ["M3GTRCAREERSTART", "RAZORMUSTANG", "BL4", "BL7"]
    var entries: [MPEntry] = []
    for i in 0..<n {
        guard let car = MultiplayerRace.makeCar(engine: engine, id: ids[i], paint: MultiplayerRace.stockPaints[i]) else { fputs("sin coche \(ids[i])\n", stderr); exit(1) }
        entries.append(MPEntry(device: PlayerDeviceList.shared.keyboard, car: car, name: (engine.ui?.es ?? true ? "JUGADOR " : "PLAYER ") + "\(i + 1)"))
    }
    var settings = QRSettings()
    settings.opponents = RaceTestOptions.opponents ?? 0
    settings.laps = 1
    settings.traffic = 1
    var outcome: RaceOutcome?
    let t0 = CACurrentMediaTime()
    guard let session = MultiplayerRace.start(engine: engine, event: event, entries: entries, settings: settings, displays: displays,
                                              autopilot: true, onEnd: { outcome = $0 }) else { fputs("No se pudo montar la prueba\n", stderr); exit(1) }
    print(String(format: "Pantalla partida: %d jugadores · %d pantalla(s) · %d×%d · prueba %@ · montaje %.2f s", n, displays, W, H, event.eventId, CACurrentMediaTime() - t0))

    var clock = 0.0
    func render(_ dt: Float) -> (gpu: Double, cpu: Double) {
        let c0 = CACurrentMediaTime()
        var gpu = 0.0
        for (d, t) in targets.enumerated() {
            let cb = engine.queue.makeCommandBuffer()!
            if d == 0 { engine.frame(cb: cb, target: t, dt: dt, scale: o.scale ?? 1, now: clock) }
            else { engine.renderDisplay(d, cb: cb, target: t, scale: o.scale ?? 1) }
            cb.commit(); cb.waitUntilCompleted()
            gpu += (cb.gpuEndTime - cb.gpuStartTime) * 1000
        }
        return (gpu, (CACurrentMediaTime() - c0) * 1000 - 0)
    }
    waitForStreaming(engine) { clock += 1.0 / 60; _ = render(0) }

    let seconds = o.seconds != 20 ? o.seconds : 40
    let base = o.screenshot.map { ($0 as NSString).deletingPathExtension }
    func shot(_ tag: String) {
        guard let b = base else { return }
        for (d, t) in targets.enumerated() { writePNG(t, device: device, queue: engine.queue, path: b + "-\(tag)" + (displays > 1 ? "-pantalla\(d + 1)" : "") + ".png") }
    }
    var gpu: [Double] = [], cpu: [Double] = [], draws: [Int] = []
    var lastLog = -1
    for i in 0..<Int(seconds * 60) {
        clock += 1.0 / 60
        let r = render(1.0 / 60)
        if i > 30 { gpu.append(r.gpu); cpu.append(r.cpu); draws.append(engine.renderer.lastDrawCalls) }
        if i == 60 * 4 { shot("start") }
        if i == Int(seconds * 60 * 0.6) { shot("mid") }
        let sec = Int(session.clock)
        if session.phase == .racing && sec != lastLog && sec % 10 == 0 {
            lastLog = sec
            print(String(format: "  [%3d s] ", sec) + session.racers.sorted { $0.position < $1.position }.map { r in
                String(format: "%d.%@ %.0fm %.0fkm/h", r.position, r.name, r.progress, abs(r.car.speed) * 3.6)
            }.joined(separator: " | "))
        }
        if session.phase == .results { if i % 20 == 10 { engine.keys.insert(36) } else if i % 20 == 12 { engine.keys.remove(36) } }
        if outcome != nil { break }
    }
    shot("end")
    let over = gpu.filter { $0 > 16.7 }.count
    print(String(format: "Rendimiento %d jugadores, %d pantalla(s) de %d×%d: GPU med %.2f ms p95 %.2f máx %.2f · CPU med %.2f ms p95 %.2f · %.1f%% > 16,7 ms · %d llamadas",
                 n, displays, W, H, median(gpu), pct(gpu, 0.95), gpu.max() ?? 0, median(cpu), pct(cpu, 0.95), Double(over) * 100 / Double(max(1, gpu.count)),
                 draws.last ?? 0))
    if let b = base {
        let js: [String: Any] = ["players": n, "displays": displays, "size": [W, H], "event": event.eventId,
                                 "gpuMedianMs": median(gpu), "gpuP95Ms": pct(gpu, 0.95), "cpuMedianMs": median(cpu), "cpuP95Ms": pct(cpu, 0.95),
                                 "framesOver16ms": over, "frames": gpu.count,
                                 "racers": session.racers.map { ["name": $0.name, "human": $0.isHuman, "position": $0.position, "progress": $0.progress] }]
        if let d = try? JSONSerialization.data(withJSONObject: js, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: URL(fileURLWithPath: b + ".json")) }
    }
    if outcome == nil { session.abandon() }
    exit(0)
}

/// `--quickrace-test`: se completa en UI/QuickRaceFlow.swift (QuickRaceFlow.runTest).
func runQuickRaceTest(_ o: Options) {
    let (device, engine) = makeMPTestEngine(o)
    QuickRaceFlow.runTest(o, device: device, engine: engine)
}
