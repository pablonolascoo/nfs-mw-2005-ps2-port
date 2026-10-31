// Prueba sin ventana del prólogo (D-Day) de punta a punta:
//   Rockport --prologue-test [--screenshot base.png] [--data …]
// Carrera nueva → las 5 pruebas de sDDayRaces con el piloto automático (los guiones del disco hacen su parte: llamada de
// Mia, fundido, policía, 911, motor saboteado) → arresto → concesionario (se compra un coche) → al garaje con el GPS
// del guion → bin 15. Comprueba cada paso y termina con código 0 si todo cuadra.
import Foundation
import Metal
import QuartzCore
import simd

enum PrologueTestOptions { static var enabled: Bool { CommandLine.arguments.contains("--prologue-test") } }

func runPrologueTest(_ o: Options) {
    setvbuf(stdout, nil, _IOLBF, 0)   // una línea cada vez (se sigue en vivo)
    guard let device = MTLCreateSystemDefaultDevice() else { fputs("sin GPU Metal\n", stderr); exit(1) }
    let (root, tried) = DataLocator.locate(arg: o.data, disc: o.disc)
    guard let root, let data = try? GameData(root: root) else { fputs("No encuentro datos:\n\(tried.joined(separator: "\n"))\n", stderr); exit(1) }
    guard let engine = try? Engine(device: device, data: data, outputFormat: .bgra8Unorm) else { fputs("motor\n", stderr); exit(1) }
    let ui = engine.enableUI(outputFormat: .bgra8Unorm)
    ui?.startGame()
    guard let sys = engine.enableRaces() else { fputs("sin races.json\n", stderr); exit(1) }
    _ = GarageSystem.attach(engine)
    let career = Career.shared, pro = Prologue.shared
    career.persist = false
    var lines: [String] = []
    let log: (String) -> Void = { s in print(s); lines.append(s) }
    sys.log = log; pro.log = log; career.log = log
    var steps: [String] = []
    pro.onStep = { s in steps.append(s); log("== paso: \(s)") }

    let (W, H) = o.size
    engine.aspect = Float(W) / Float(H)
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
    td.usage = [.renderTarget, .shaderRead]; td.storageMode = .private
    let target = device.makeTexture(descriptor: td)!
    if let ai = engine.ai { let t0 = CACurrentMediaTime(); while !ai.models.allIdle && CACurrentMediaTime() - t0 < 60 { usleep(20000) } }
    var clock = 0.0
    func render(_ dt: Float) {
        let cb = engine.queue.makeCommandBuffer()!
        engine.frame(cb: cb, target: target, dt: dt, scale: o.scale ?? 1, now: clock)
        cb.commit(); cb.waitUntilCompleted()
    }
    func settle() {   // casillas alrededor del coche con la simulación parada
        let l0 = CACurrentMediaTime()
        while CACurrentMediaTime() - l0 < 60 {
            clock += 1.0 / 60; render(0)
            let s = engine.streamer.stats
            if engine.streamer.idle && s.nearReady == s.near { break }
            usleep(4000)
        }
    }

    career.newGame()
    let save0 = career.save
    log("Partida nueva: bin \(save0.currentBin) · \(save0.cash) $ · coche \(save0.currentCar)")
    let base = o.screenshot.map { ($0 as NSString).deletingPathExtension }
    var shots = Set<String>()
    var lastSession: ObjectIdentifier?
    var bought = false, teleported = false
    var i = 0
    let maxFrames = 60 * 60 * 30   // 30 min simulados
    while i < maxFrames {
        if let s = sys.session, ObjectIdentifier(s) != lastSession { lastSession = ObjectIdentifier(s); settle() }
        clock += 1.0 / 60; i += 1
        render(1.0 / 60)
        if let s = sys.session { if !s.autopilot { s.autopilot = true } }
        // Ventanas modales (resultados, BUSTED, mensajes): Intro como el jugador
        if engine.ui?.paused == true { if i % 20 == 10 { engine.keys.insert(36) } else if i % 20 == 12 { engine.keys.remove(36) } }
        else if i % 20 == 12 { engine.keys.remove(36) }
        if let b = base, let s = sys.session, s.phase == .racing, s.clock > 8, !shots.contains(s.event.eventId) {
            shots.insert(s.event.eventId); writePNG(target, device: device, queue: engine.queue, path: "\(b)-\(s.event.eventId).png")
        }
        // Concesionario: se compra el primer coche asequible (lo que haría el jugador en Car_Select)
        if pro.waitingForCar && !bought {
            bought = true
            let lot = FEUI.lotCars(engine.data).filter { $0.cost <= career.save.cash && career.save.currentBin <= $0.unlockedAt }.sorted { $0.cost > $1.cost }
            let pick = lot.first?.model ?? "GTI"
            let cost = lot.first?.cost ?? 0
            career.modifySave { $0.cash -= cost; $0.cars.append(pick); $0.currentCar = pick }
            CarTuning.replacePlayerCar(engine, key: pick)
            log("Concesionario: comprado \(pick) por \(cost) $ (quedan \(career.save.cash) $)")
            if let b = base { writePNG(target, device: device, queue: engine.queue, path: "\(b)-concesionario.png") }
        }
        // Al garaje: el GPS del guion marca el destino; el coche se lleva allí (la conducción ya está probada en las carreras)
        if let gps = pro.gpsTarget, pro.drive != nil, !teleported, let car = engine.car {
            teleported = true
            if let b = base { writePNG(target, device: device, queue: engine.queue, path: "\(b)-gps.png") }
            log(String(format: "Viaje al garaje: GPS en (%.0f, %.0f, %.0f), coche en (%.0f, %.0f)", gps.x, gps.y, gps.z, car.position.x, car.position.y))
            car.place(gps + float3(0, 0, 2), yaw: car.yaw, collision: engine.collision, probe: 30)
        }
        if steps.last == "done" { break }
    }
    if let b = base { writePNG(target, device: device, queue: engine.queue, path: "\(b)-final.png") }
    let s = career.save
    let expect = ["race:16.1.0", "race:16.2.2", "race:16.2.3", "race:16.1.1", "race:16.2.1", "carlot", "drive", "done"]
    let racesInOrder = steps.filter { $0.hasPrefix("race:") }
    let uniqueRaces = racesInOrder.reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } }
    let flowOK = expect.allSatisfy(steps.contains) && uniqueRaces == expect.prefix(5).map { $0 }
    let joined = lines.joined(separator: "\n")
    let checks: [(String, Bool)] = [
        ("orden de sDDayRaces y pasos completos", flowOK),
        ("16.1.0: llamada de Mia (ECellCall 10)", joined.contains("guion: llamada 10")),
        ("16.1.0: termina por el guion (fundido → postrace)", joined.contains("16.1.0: terminada por el guion")),
        ("16.2.3: policía de guion", joined.contains("guion: policía")),
        ("16.2.1: motor saboteado y reventado", joined.contains("motor saboteado") && joined.contains("motor reventado")),
        ("16.2.1: termina por el guion", joined.contains("16.2.1: terminada por el guion")),
        ("arresto: sin el BMW", !s.cars.contains(Prologue.startCar)),
        ("drive_to_safe_house: SMS 15 y GPS", joined.contains("SMS 15") && joined.contains("GPS al garaje")),
        ("al llegar: estado at_target", joined.contains("estado «at_target»")),
        ("Lista Negra: bin 15", s.currentBin == 15),
    ]
    print("\n── Prólogo: comprobaciones")
    for (n, ok) in checks { print("  \(ok ? "✔" : "✘") \(n)") }
    print("  pasos: \(steps.joined(separator: " → "))")
    print("  partida: bin \(s.currentBin) · \(s.cash) $ · coches \(s.cars) · pruebas \(s.racesWon)")
    print(String(format: "  %d fotogramas (%.1f min simulados)", i, Double(i) / 3600))
    if let b = base { try? lines.joined(separator: "\n").write(toFile: b + ".log", atomically: true, encoding: .utf8) }
    exit(checks.allSatisfy(\.1) ? 0 : 1)
}
