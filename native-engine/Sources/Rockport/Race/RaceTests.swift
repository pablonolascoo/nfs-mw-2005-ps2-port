// Pruebas sin ventana de las carreras y de la Lista Negra.
//
//   Rockport --race-test <EventID|colección> [--seconds N] [--autodrive] [--screenshot salida.png] [--size AxB] [--data …]
//       Corre la prueba con el piloto automático del jugador (el mismo conductor que la IA, habilidad 1). Escribe en la
//       consola los puntos de control, posiciones y tiempos; capturas al empezar (-start), a mitad (-mid) y al final; y un
//       JSON con el resumen junto a la captura.
//   Rockport --career-test [--save ruta.json] [--data …]
//       Simula la progresión de la Lista Negra (15 → 1) con resultados sintéticos: pruebas ganadas, hitos, recompensa,
//       carreras del rival, coche ganado, cambio de vallas de la historia y guardado/carga de la partida.
import Foundation
import Metal
import QuartzCore
import simd

enum RaceTestOptions {
    static var args: [String] { CommandLine.arguments }
    static func value(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    static var raceTest: String? { value("--race-test") }
    static var careerTest: Bool { args.contains("--career-test") }
    static var raceAudit: Bool { args.contains("--race-audit") }
    static var autodrive: Bool { args.contains("--autodrive") }
    static var opponents: Int? { value("--opponents").flatMap(Int.init) }
}

private func makeTestEngine(_ o: Options) -> (MTLDevice, Engine) {
    guard let device = MTLCreateSystemDefaultDevice() else { fputs("sin GPU Metal\n", stderr); exit(1) }
    let (root, tried) = DataLocator.locate(arg: o.data, disc: o.disc)
    guard let root, let data = try? GameData(root: root) else { fputs("No encuentro datos. Buscado en:\n\(tried.joined(separator: "\n"))\n", stderr); exit(1) }
    do { return (device, try Engine(device: device, data: data, outputFormat: .bgra8Unorm)) } catch { fputs("motor: \(error)\n", stderr); exit(1) }
}

func runRaceTest(_ o: Options, eventKey: String) {
    let (device, engine) = makeTestEngine(o)
    if let g = o.grade { engine.renderer.gradeStrength = g }
    let ui = o.noUI ? nil : engine.enableUI(outputFormat: .bgra8Unorm)
    ui?.startGame()
    guard let sys = engine.enableRaces() else { fputs("Carreras no disponibles (falta races.json)\n", stderr); exit(1) }
    Career.shared.persist = false
    guard let event = sys.db.event(eventKey) else { fputs("No existe la prueba «\(eventKey)»\n", stderr); exit(1) }
    let (W, H) = o.size
    engine.aspect = Float(W) / Float(H)
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
    td.usage = [.renderTarget, .shaderRead]; td.storageMode = .private
    let target = device.makeTexture(descriptor: td)!

    // Modelos de la IA (tráfico/policía) antes de empezar
    if let ai = engine.ai { let t0 = CACurrentMediaTime(); while !ai.models.allIdle && CACurrentMediaTime() - t0 < 60 { usleep(20000) } }
    var lines: [String] = []
    sys.log = { s in print(s); lines.append(s) }
    let t0 = CACurrentMediaTime()
    guard let session = sys.start(event, context: .test, opponents: RaceTestOptions.opponents) else { fputs("No se pudo montar la prueba\n", stderr); exit(1) }
    print(String(format: "Montaje de la prueba: %.2f s (rivales: %@)", CACurrentMediaTime() - t0, session.racers.filter { !$0.isPlayer }.map { "\($0.name) [\($0.car.specs?.model ?? "?")]" }.joined(separator: ", ")))
    session.autopilot = RaceTestOptions.autodrive
    var outcome: RaceOutcome?
    let prevEnd = session.onEnd
    session.onEnd = { o in prevEnd?(o); outcome = o }

    var clock = 0.0
    func render(_ dt: Float) -> (Double, Double) {
        let c0 = CACurrentMediaTime()
        let cb = engine.queue.makeCommandBuffer()!
        engine.frame(cb: cb, target: target, dt: dt, scale: o.scale ?? 1, now: clock)
        cb.commit()
        let cpu = (CACurrentMediaTime() - c0) * 1000
        cb.waitUntilCompleted()
        return ((cb.gpuEndTime - cb.gpuStartTime) * 1000, cpu)
    }
    // Carga de casillas alrededor de la salida (la simulación está parada: dt = 0)
    let l0 = CACurrentMediaTime()
    while true {
        clock += 1.0 / 60; _ = render(0)
        let s = engine.streamer.stats
        if engine.streamer.allFarLoaded && engine.streamer.idle && s.nearReady == s.near && clock > 0.5 { break }
        if CACurrentMediaTime() - l0 > 120 { break }
        usleep(5000)
    }
    print(String(format: "Carga de la salida: %.2f s", CACurrentMediaTime() - l0))

    let est = Double(max(60, session.route.length / 28)) + 20
    let seconds = o.seconds != 20 ? o.seconds : min(600, est)
    let frames = Int(seconds * 60)
    let base = o.screenshot.map { ($0 as NSString).deletingPathExtension }
    var gpu: [Double] = [], cpu: [Double] = []
    var shotStart = false, shotMid = false, shotResults = false
    var resultsFrames = 0
    var lastLog = -1
    var endFrame: Int?
    for i in 0..<frames {
        clock += 1.0 / 60
        let r = render(1.0 / 60)
        gpu.append(r.0); cpu.append(r.1)
        if let b = base {
            if !shotStart && i == 90 { shotStart = true; writePNG(target, device: device, queue: engine.queue, path: b + "-start.png") }
            let half = session.route.length * 0.5
            if !shotMid && (session.player.progress >= half || (session.event.kind == .challenge && i == frames / 2)) {
                shotMid = true; writePNG(target, device: device, queue: engine.queue, path: b + "-mid.png")
            }
        }
        if i % 1200 == 600, ProcessInfo.processInfo.environment["ROCKPORT_DEBUG_RACE"] != nil {
            print("  [marco \(i)] fase \(session.phase) reloj \(String(format: "%.1f", session.clock)) pausa \(engine.ui?.paused ?? false) estado \(engine.ui.map { "\($0.state)" } ?? "-") modo \(engine.mode)")
        }
        let sec = Int(session.clock)
        if session.phase == .racing && sec != lastLog && sec % 10 == 0 {
            lastLog = sec
            let rank = session.racers.sorted { $0.position < $1.position }
            print(String(format: "  [%3d s] ", sec) + rank.map { r in
                String(format: "%d.%@ %.0fm %.0fkm/h%@", r.position, r.isPlayer ? "JUG" : r.name, r.progress, abs(r.car.speed) * 3.6, r.resets > 0 ? " r\(r.resets)" : "")
            }.joined(separator: " | "))
        }
        // Pantalla de resultados (modal de la interfaz): se acepta con Intro como lo haría el jugador
        if session.phase != .results, engine.ui?.paused == true {   // otra pantalla modal (BUSTED…): se acepta
            if i % 20 == 10 { engine.keys.insert(36) } else if i % 20 == 12 { engine.keys.remove(36) }
        }
        if session.phase == .results {
            resultsFrames += 1
            // Captura con la pantalla ya asentada (el HUD tarda unos fotogramas en ocultarse) y luego Intro
            if !shotResults, let b = base, resultsFrames == 60 { shotResults = true; writePNG(target, device: device, queue: engine.queue, path: b + "-results.png") }
            if resultsFrames > 70 { if i % 20 == 10 { engine.keys.insert(36) } else if i % 20 == 12 { engine.keys.remove(36) } }
        }
        if outcome != nil && endFrame == nil { endFrame = i; engine.keys.remove(36) }
        if let e = endFrame, i - e > 30 { break }
    }
    if outcome == nil { print("Tiempo de prueba agotado (\(Int(seconds)) s) sin terminar la carrera"); session.abandon() }
    if let b = base { writePNG(target, device: device, queue: engine.queue, path: b + "-finish.png") }
    let rs = session.racers
    print(String(format: "Rendimiento %d×%d: CPU med %.2f ms p95 %.2f · GPU med %.2f ms p95 %.2f · %d corredores", W, H, median(cpu), pct(cpu, 0.95), median(gpu), pct(gpu, 0.95), rs.count))
    if let b = base {
        let js: [String: Any] = [
            "event": event.id, "eventId": event.eventId, "kind": event.kind.rawValue, "routeLength": session.route.length, "dataLength": event.length,
            "legErrors": session.route.legErrors, "gates": session.gates.count, "won": outcome?.playerWon ?? false,
            "playerPosition": outcome?.playerPosition ?? 0, "playerTime": outcome?.playerTime ?? -1,
            "racers": rs.map { ["name": $0.name, "player": $0.isPlayer, "position": $0.position, "time": $0.finishTime ?? -1, "progress": $0.progress,
                                "resets": $0.resets, "knockedOut": $0.knockedOut, "dnf": $0.dnfReason, "topSpeedKmh": $0.topSpeed * 3.6,
                                "speedtrapKmh": $0.speedtrapTotal * 3.6] },
            "cpuMedianMs": median(cpu), "cpuP95Ms": pct(cpu, 0.95), "gpuMedianMs": median(gpu), "gpuP95Ms": pct(gpu, 0.95), "log": lines,
        ]
        if let d = try? JSONSerialization.data(withJSONObject: js, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: URL(fileURLWithPath: b + ".json")) }
    }
    exit(outcome == nil ? 2 : 0)
}

/// Progresión sintética de la Lista Negra: comprueba reglas, recompensas, vallas y partida guardada.
func runCareerTest(_ o: Options) {
    let (_, engine) = makeTestEngine(o)
    guard let sys = engine.enableRaces() else { fputs("Carreras no disponibles (falta races.json)\n", stderr); exit(1) }
    let career = Career.shared
    let path = RaceTestOptions.value("--save") ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("rockport-career-test.json")
    career.saveURL = URL(fileURLWithPath: path)
    career.persist = true
    career.newGame()
    var problems: [String] = []
    func check(_ c: Bool, _ m: String) { if !c { problems.append(m); print("  ✗ " + m) } }
    print("Prueba de carrera profesional · partida en \(path)")
    var guardN = 0
    while career.save.currentBin >= 1 && guardN < 40 {
        guardN += 1
        guard let b = career.bin() else { problems.append("falta el bin \(career.save.currentBin)"); break }
        let locks = sys.world.activeNames.filter { $0.hasPrefix("BARRIER_LOCKED") }.sorted()
        print("Bin \(b.binIndex) · rival \(b.bossName) (\(b.bossPreset ?? "—")) · candados activos: \(locks.isEmpty ? "ninguno" : locks.joined(separator: " ")) · muros dinámicos \(engine.collision.dynamicWalls.count)")
        check(Set(locks) == Set(b.barriers.map(\.group).filter { $0.hasPrefix("BARRIER_LOCKED") }), "bin \(b.binIndex): candados distintos de los del bin")
        check(!career.canChallengeRival() || (b.requiredRacesWon == 0 && b.requiredChallenges == 0 && b.requiredBounty <= career.save.bounty), "bin \(b.binIndex): rival disponible antes de cumplir requisitos")
        // Pruebas del mundo ganadas (resultado sintético)
        for id in b.worldRaces.prefix(b.requiredRacesWon) {
            guard let e = sys.db.event(id) else { problems.append("bin \(b.binIndex): falta la prueba \(id)"); continue }
            career.record(RaceOutcome(event: e, context: .career, playerWon: true, playerPosition: 1, playerTime: 120, abandoned: false, rows: [],
                                      cash: Int(e.cash), bounty: Int(e.reputation), milestoneValue: nil))
        }
        // Hitos de persecución del bin
        for id in b.milestones.prefix(b.requiredChallenges) { career.applyMilestone(id) }
        // Recompensa que falte (persecuciones evadidas)
        if career.save.bounty < b.requiredBounty { career.addBounty(b.requiredBounty - career.save.bounty) }
        print("  " + career.progressText())
        check(career.canChallengeRival(), "bin \(b.binIndex): requisitos cumplidos pero el rival no está disponible")
        // Carreras del rival en orden
        var n = 0
        while let e = career.nextBossRace(), n < 10 {
            n += 1
            print("  carrera del rival: \(e.eventId) \(e.kind.rawValue) (\(e.id))")
            career.record(RaceOutcome(event: e, context: .career, playerWon: true, playerPosition: 1, playerTime: 100, abandoned: false, rows: [],
                                      cash: Int(e.cash), bounty: Int(e.reputation), milestoneValue: nil))
            if career.save.currentBin != b.binIndex { break }
        }
        check(career.save.rivalsDefeated.contains(b.binIndex), "bin \(b.binIndex): rival no vencido tras ganar sus carreras")
        if let p = b.bossPreset, !p.isEmpty { check(career.save.cars.contains(p), "bin \(b.binIndex): no se ganó el coche \(p)") }
    }
    // Guardado y carga
    let loaded = CareerSave.load(career.saveURL)
    check(loaded != nil, "no se pudo leer la partida guardada")
    if let l = loaded { check(l.currentBin == career.save.currentBin && l.cars == career.save.cars && l.bounty == career.save.bounty, "la partida cargada no coincide") }
    print("Final: bin \(career.save.currentBin) · rivales vencidos \(career.save.rivalsDefeated.count) · coches \(career.save.cars.joined(separator: ", ")) · \(career.save.cash) $ · recompensa \(career.save.bounty)")
    let locks = sys.world.activeNames.filter { $0.hasPrefix("BARRIER_LOCKED") }
    print("Candados al terminar: \(locks.isEmpty ? "ninguno (ciudad abierta)" : locks.joined(separator: " "))")
    if problems.isEmpty { print("Carrera profesional: todo bien") } else { print("Problemas (\(problems.count)):"); problems.forEach { print("  " + $0) } }
    try? FileManager.default.removeItem(atPath: path)
    exit(problems.isEmpty ? 0 : 1)
}

/// `--race-audit`: construye la ruta de todas las pruebas y la compara con RaceLength del juego.
func runRaceAudit(_ o: Options) {
    let (_, engine) = makeTestEngine(o)
    guard let sys = engine.enableRaces(), let net = engine.ai?.net else { fputs("Carreras no disponibles\n", stderr); exit(1) }
    var rows: [(String, Float, Float, Int)] = []
    var errors = 0
    for e in sys.db.events {
        guard let start = e.start else { continue }
        var lap = e.checkpoints; if let f = e.finish { lap.append(f) }
        if lap.isEmpty { continue }
        let r = RaceRoute(net: net, barriers: sys.world.lines(for: e.barriers), start: start, gates: lap, laps: max(1, e.laps))
        rows.append((e.eventId + " " + e.kind.rawValue, r.length, e.length, r.legErrors))
        errors += r.legErrors
    }
    let withLen = rows.filter { $0.2 > 0 }
    let ratios = withLen.map { Double($0.1 / $0.2) }.sorted()
    let within = withLen.filter { abs($0.1 / $0.2 - 1) < 0.1 }.count
    print(String(format: "Rutas: %d pruebas · %d tramos sin camino · con RaceLength: %d · ruta/dato mediana %.3f (p10 %.3f, p90 %.3f) · dentro del ±10 %%: %d",
                 rows.count, errors, withLen.count, median(ratios), pct(ratios, 0.1), pct(ratios, 0.9), within))
    for r in withLen.sorted(by: { abs($0.1 / $0.2 - 1) > abs($1.1 / $1.2 - 1) }).prefix(12) {
        print(String(format: "  %@: ruta %.0f m · dato %.0f m (%.2f) · sin camino %d", r.0, r.1, r.2, r.1 / r.2, r.3))
    }
    exit(0)
}
