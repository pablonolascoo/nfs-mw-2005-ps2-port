// Enganche de la IA (tráfico y policía) en el motor, y la prueba sin ventana `--traffic-test N`.
//
// Opciones (también en la app):
//   --traffic-test N   simula N segundos sin ventana: un coche de prueba recorre la red (rápido, luego se para),
//                      guarda una captura y escribe estadísticas (aparecidos, violaciones de carril, persecuciones…)
//   --traffic-max N    máximo de coches de tráfico (20; el PS2 usa 10 vehículos en total [D])
//   --heat H           calor inicial (1…5)
//   --no-traffic / --no-police
import Foundation
import Metal
import QuartzCore
import simd

enum AIOptions {
    static var args: [String] { CommandLine.arguments }
    static func value(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    static var trafficTest: Double? { value("--traffic-test").flatMap(Double.init) }
    static func apply() {
        if let n = value("--traffic-max").flatMap(Int.init) { AIConfig.maxTraffic = max(0, n) }
        if args.contains("--no-traffic") { AIConfig.maxTraffic = 0 }
        if args.contains("--no-police") { AIConfig.police = false }
    }
}

extension Engine {
    func setupAI(outputFormat: MTLPixelFormat) {
        AIOptions.apply()
        guard ai == nil, let w = AIWorld(device: device, data: data, textures: textures, collision: collision) else { return }
        if let h = AIOptions.value("--heat").flatMap(Float.init) { w.police.heat = max(1, min(AIConfig.maxOpenWorldHeat, h)) }
        // Luz del mando (DualShock 4 / DualSense) en rojo y azul durante la persecución (Input/Controllers.swift)
        w.onPursuitChanged = { active in
            Controllers.shared.setPursuit(active: active)
            AIControllerLink.pursuitChanged?(active)
        }
        // Arrestado: el coche vuelve al refugio 1 (como volver a la partida tras la pantalla de BUSTED) [I]
        w.police.onBusted = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.respawnAfterBust() }
        }
        do {
            let r = try AIRenderer(device: device, textures: textures, world: w, outputFormat: outputFormat)
            renderer.overlays.append(r)
            aiRenderer = r
        } catch { fputs("IA: no se pudo crear el render: \(error)\n", stderr); return }
        ai = w
        print("IA: \(w.net.count) segmentos · \(w.tables.trafficPatterns.count) patrones de tráfico · \(w.tables.heatLevels.count) niveles de calor · \(w.tables.zones.count) zonas")
    }

    private func respawnAfterBust() {
        guard let car, let z = data.zones.first(where: { $0.zoneType == "safehouse" }), let r = z.respawn, r.position.count == 3 else { return }
        car.place(float3(r.position[0], r.position[1], r.position[2]), yaw: (r.rotation ?? 0) * .pi / 180, collision: collision)
    }

    /// Cada fotograma, tras la simulación del jugador y antes de dibujar.
    func updateAI(dt: Float, frame: SceneFrame) {
        guard let ai else { return }
        var p = AIPlayer()
        if let tp = AITestDriver.current {
            p = tp.playerState
        } else if mode == .drive, let car {
            p.exists = true
            p.pos = car.position; p.yaw = car.yaw
            p.speed = simd_dot(car.velocity, car.forward)
            p.halfLength = car.halfLength; p.halfWidth = car.halfWidth
        }
        let v = frame.view
        let camFwd = -float3(v.columns.0.z, v.columns.1.z, v.columns.2.z)
        ai.update(dt: dt, player: p, cameraPos: frame.camPos, cameraFwd: camFwd, viewProj: frame.proj * frame.view)
        // Golpes contra la IA: el coche del jugador pierde velocidad (la física del juego no tiene aún choques entre coches)
        let f = ai.playerSpeedFactor
        ai.playerSpeedFactor = 1
        if f < 0.999, AITestDriver.current == nil, mode == .drive, let car {
            if let veh = car.vehicle { veh.rb.linearVel *= f } else { car.speed *= f }
        }
    }
}

/// Otros oyentes de «persecución sí/no» (música, sonido…). La luz del mando ya se avisa directamente.
enum AIControllerLink {
    static var pursuitChanged: ((Bool) -> Void)?
}

// MARK: - Prueba sin ventana

/// Coche de prueba: recorre la red por un carril como un coche de la IA, pero sin frenar por el tráfico.
/// Fases: 0–55 % a 125 km/h (provoca persecuciones), 55–75 % a 70 km/h, 75–100 % parado (para ver el arresto).
final class AITestDriver {
    static var current: AITestDriver?
    /// Guion: "busted" (por defecto: rápido, despacio y parado), "run" (siempre a 130 km/h) o "flee" (300 km/h en cuanto
    /// empieza la persecución, para ver el enfriamiento y la evasión). `--test-plan`.
    static var plan = AIOptions.value("--test-plan") ?? "busted"
    let v: AIVehicle
    var duration: Float
    var t: Float = 0
    var rng = SplitMix(seed: 42)
    init(v: AIVehicle, duration: Float) { self.v = v; self.duration = duration }

    var playerState: AIPlayer {
        var p = AIPlayer()
        p.exists = true; p.pos = v.pos; p.yaw = v.yaw; p.speed = v.speed
        p.halfLength = v.model.halfLength; p.halfWidth = v.model.halfWidth
        return p
    }

    func step(_ w: AIWorld, dt: Float) {
        t += dt
        let f = t / duration
        var want: Float = AITestDriver.plan == "run" ? 36 : (f < 0.55 ? 34.7 : f < 0.75 ? 19.4 : 0)
        // "flee": 130 km/h hasta que empieza la persecución y luego 300 km/h (un deportivo deja atrás al Crown Victoria)
        if AITestDriver.plan == "flee" { want = w.police.inPursuit || w.police.state == .evaded ? 83 : 36 }
        if want > v.speed { v.speed = min(want, v.speed + 7 * dt) } else { v.speed = max(want, v.speed - 9 * dt) }
        // golpes: el jugador de prueba pierde velocidad igual que el de verdad
        v.speed *= w.playerSpeedFactor
        w.playerSpeedFactor = 1
        v.advance(net: w.net, step: v.speed * dt, cops: false, field: nil, rng: &rng)
        v.pose(net: w.net, collision: w.collision, dt: dt)
        v.spin += v.speed * dt / v.model.wheelRadius
        v.braking = want < v.speed - 0.3
    }
}

func runTrafficTest(_ o: Options, seconds: Double) {
    guard let device = MTLCreateSystemDefaultDevice() else { fputs("sin GPU Metal\n", stderr); exit(1) }
    let (root, tried) = DataLocator.locate(arg: o.data, disc: o.disc)
    guard let root, let data = try? GameData(root: root) else { fputs("No encuentro datos. Buscado en:\n\(tried.joined(separator: "\n"))\n", stderr); exit(1) }
    let engine: Engine
    do { engine = try Engine(device: device, data: data, outputFormat: .bgra8Unorm) } catch { fputs("motor: \(error)\n", stderr); exit(1) }
    guard let ai = engine.ai, let air = engine.aiRenderer else { fputs("IA no disponible (faltan roads.json o ai.json)\n", stderr); exit(1) }
    if let g = o.grade { engine.renderer.gradeStrength = g }
    let (W, H) = o.size
    engine.aspect = Float(W) / Float(H)
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
    td.usage = [.renderTarget, .shaderRead]; td.storageMode = .private
    let target = device.makeTexture(descriptor: td)!

    // Coche de prueba: el del jugador, en el carril más cercano al refugio 1
    var start = engine.camPos
    if let z = data.zones.first(where: { $0.zoneType == "safehouse" }), let r = z.respawn, r.position.count == 3 { start = float3(r.position[0], r.position[1], r.position[2]) }
    if let c = o.camera, c.count >= 3 { start = float3(c[0], c[1], c[2]) }
    ai.models.preload([Config.playerCar])
    let t0 = CACurrentMediaTime()
    while (!ai.models.allIdle || ai.models.model(Config.playerCar) == nil) && CACurrentMediaTime() - t0 < 60 { usleep(20000) }
    guard let pm = ai.models.model(Config.playerCar),
          let hit = ai.net.nearest(start, maxDist: 300, filter: { ai.net.trafficAllowed($0) && !ai.net.segs[$0].has(RoadSegFlags.decision) }) else {
        fputs("no hay carretera cerca del punto de partida\n", stderr); exit(1)
    }
    let pv = AIVehicle(id: 0, kind: .traffic, model: pm, typeName: "player")
    pv.place(net: ai.net, seg: hit.seg, forward: !ai.net.segs[hit.seg].has(RoadSegFlags.oneWay) ? true : true, t: hit.t, lane: 0, collision: ai.collision)
    let driver = AITestDriver(v: pv, duration: Float(seconds))
    AITestDriver.current = driver
    air.extraVehicles = [pv]
    print("Prueba de tráfico: \(seconds) s desde (\(Int(pv.pos.x)), \(Int(pv.pos.y))) · \(W)×\(H)")

    var clock = 0.0
    func render(_ dt: Float) -> (Double, Double) {
        let c0 = CACurrentMediaTime()
        // Cámara de persecución detrás del coche de prueba (modo libre)
        let f = pv.fwd
        engine.camPos = pv.pos - f * 9 + float3(0, 0, 3.6)
        engine.yaw = pv.yaw; engine.pitch = -0.17
        let cb = engine.queue.makeCommandBuffer()!
        engine.frame(cb: cb, target: target, dt: dt, scale: 1, now: clock)
        cb.commit()
        let cpu = (CACurrentMediaTime() - c0) * 1000
        cb.waitUntilCompleted()
        return ((cb.gpuEndTime - cb.gpuStartTime) * 1000, cpu)
    }
    // Carga de casillas alrededor
    let l0 = CACurrentMediaTime()
    while true {
        clock += 1.0 / 60; _ = render(0)
        let s = engine.streamer.stats
        if engine.streamer.allFarLoaded && engine.streamer.idle && s.nearReady == s.near && clock > 0.5 { break }
        if CACurrentMediaTime() - l0 > 120 { break }
        usleep(5000)
    }
    // Esperar a los modelos de tráfico y policía
    while !ai.models.allIdle && CACurrentMediaTime() - l0 < 120 { usleep(20000) }
    print(String(format: "Carga: %.2f s · %d modelos de IA listos", CACurrentMediaTime() - l0, ai.models.loadedCount))

    var gpu: [Double] = [], cpu: [Double] = []
    let frames = Int(seconds * 60)
    var shots: [(Int, String)] = []
    if let shot = o.screenshot {
        let base = (shot as NSString).deletingPathExtension
        shots = [(frames * 30 / 100, base + "-30.png"), (frames * 60 / 100, base + "-60.png"), (frames - 1, shot)]
    }
    var stateLog: [String] = []
    let debugAI = ProcessInfo.processInfo.environment["ROCKPORT_DEBUG_AI"] != nil
    var lastState = ai.police.state
    var rbShot = false
    for i in 0..<frames {
        clock += 1.0 / 60
        driver.step(ai, dt: 1.0 / 60)
        let r = render(1.0 / 60)
        gpu.append(r.0); cpu.append(r.1)
        if ai.police.state != lastState {
            stateLog.append(String(format: "%.1f s: %@ (calor %.2f, %d policías)", Double(i) / 60, "\(ai.police.state)", ai.police.heat, ai.police.copsInPursuit))
            lastState = ai.police.state
        }
        if debugAI && i % 120 == 0 {
            let cops = ai.vehicles.filter { $0.kind == .cop }.map { c in
                String(format: "%@/%@ d=%.0f v=%.0f z=%.1f", "\(c.copRole)", "\(c.mode)", simd_distance(c.pos, pv.pos), c.speed * 3.6, c.pos.z - pv.pos.z)
            }
            print(String(format: "[%.0f s] jugador v=%.0f · %@ · visto hace %.1f s · evasión %.2f · ", Double(i) / 60, pv.speed * 3.6, "\(ai.police.state)", ai.police.timeSinceSeen, ai.police.evade) + cops.joined(separator: " | "))
        }
        if !rbShot, let rb = ai.police.roadblock, simd_distance(rb.center, pv.pos) < 110, let shot = o.screenshot {
            rbShot = true
            writePNG(target, device: device, queue: engine.queue, path: (shot as NSString).deletingPathExtension + "-control.png")
        }
        if let s = shots.first(where: { $0.0 == i }) { writePNG(target, device: device, queue: engine.queue, path: s.1) }
    }
    let st = ai.stats
    let groundPct = st.laneFrames > 0 ? 100 * Double(st.laneFrames - st.offGroundFrames) / Double(st.laneFrames) : 0
    print("— Resultado ——————————————————————————————")
    print(String(format: "Tráfico: %d aparecidos, %d borrados, máx. %d a la vez · activos al final %d (patrones: %@)",
                 st.trafficSpawned, st.trafficDespawned, st.maxTrafficActive, ai.count(.traffic), st.patternsUsed.sorted().joined(separator: ", ")))
    print(String(format: "Policía: %d aparecidos, máx. %d a la vez · persecuciones %d · evadido %d · arrestos %d · calor máx. %.2f · controles %d (esquivados %d, pinchos %d)",
                 st.copsSpawned, st.maxCopsActive, st.pursuitsStarted, st.evaded, st.busted, st.maxHeat, st.roadblocks, st.roadblocksDodged, st.spikesHit))
    print(String(format: "Carril: %d coche·fotogramas · sobre el suelo %.2f %% · saltos laterales %d · cruces de muro %d · solapes entre IA %d · golpes del jugador: %d tráfico, %d policía",
                 st.laneFrames, groundPct, st.laneSnaps, st.wallCrossings, st.aiOverlaps, st.playerHitsTraffic, st.playerHitsCops))
    print("Modelos usados: \(st.modelsUsed.sorted().joined(separator: ", "))")
    for l in stateLog { print("  persecución · " + l) }
    if debugAI {
        for (sg, n) in ai.wallSegs.sorted(by: { $0.value > $1.value }).prefix(12) {
            let p = ai.net.point(sg, 0.5)
            print(String(format: "  muros en seg %d (%d veces) flags %d en (%.0f, %.0f, %.1f)", sg, n, ai.net.segs[sg].flags, p.x, p.y, p.z))
        }
    }
    print(String(format: "Rendimiento %d×%d: GPU med %.2f ms p95 %.2f · CPU med %.2f ms p95 %.2f · %d llamadas (IA %d)",
                 W, H, median(gpu), pct(gpu, 0.95), median(cpu), pct(cpu, 0.95), engine.renderer.lastDrawCalls, air.drawCalls))
    // Estadísticas en JSON junto a la captura
    if let shot = o.screenshot {
        let js: [String: Any] = [
            "seconds": seconds, "trafficSpawned": st.trafficSpawned, "trafficDespawned": st.trafficDespawned, "maxTraffic": st.maxTrafficActive,
            "copsSpawned": st.copsSpawned, "maxCops": st.maxCopsActive, "pursuitsStarted": st.pursuitsStarted, "evaded": st.evaded, "busted": st.busted,
            "maxHeat": st.maxHeat, "roadblocks": st.roadblocks, "laneFrames": st.laneFrames, "offGroundFrames": st.offGroundFrames,
            "laneSnaps": st.laneSnaps, "wallCrossings": st.wallCrossings, "aiOverlaps": st.aiOverlaps,
            "playerHitsTraffic": st.playerHitsTraffic, "playerHitsCops": st.playerHitsCops,
            "gpuMedianMs": median(gpu), "gpuP95Ms": pct(gpu, 0.95), "cpuMedianMs": median(cpu), "cpuP95Ms": pct(cpu, 0.95),
            "patterns": st.patternsUsed.sorted(), "models": st.modelsUsed.sorted(), "pursuitLog": stateLog,
        ]
        if let d = try? JSONSerialization.data(withJSONObject: js, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: (shot as NSString).deletingPathExtension + ".json"))
        }
    }
    exit(0)
}
