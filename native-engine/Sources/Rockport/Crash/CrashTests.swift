// Pruebas sin ventana de los choques y del helicóptero.
//
//   --crash-test [frontal|lateral|pit|rompibles|derrumbe|rendimiento|all] [--screenshot base.png] [--size AxB]
//       Escenarios con guion sobre un tramo recto real de Rockport (cerca del refugio 1):
//         frontal     BMW del jugador a 90 km/h contra un coche de tráfico de cara a 50 km/h
//         lateral     BMW a 100 km/h contra el costado de un coche de policía parado (dos veces: daños y destrucción)
//         pit         policía que embiste la aleta trasera del jugador a 110 km/h (maniobra PIT)
//         rompibles   BMW a 80 km/h por una fila de rompibles reales del mapa (señales, bolardos, conos…)
//         derrumbe    derrumbe de persecución (gasolinera/depósito/andamio) con dos policías debajo, persecución activa
//         rendimiento 30 coches (tráfico + policía) circulando con choques activos: coste por fotograma
//       Comprobaciones: impulsos y solapes (penetración máxima entre volúmenes tras resolver), daños por zona,
//       sonidos de golpe, contadores de la HUD, coste de CrashWorld.step. Capturas <base>-<escenario>-N.png y JSON.
//   --heli-test N [--screenshot base.png]
//       Persecución de calor 5 con el coche de prueba (como --traffic-test --test-plan run) y el helicóptero forzado:
//       registro de aparición, distancia al jugador, línea de visión, combustible y retirada; capturas con el
//       helicóptero a la vista y el radar de la HUD.
import Foundation
import Metal
import QuartzCore
import simd

private final class CrashTestRig {
    let engine: Engine
    let device: MTLDevice
    let target: MTLTexture
    let ai: AIWorld
    let crash: CrashWorld
    var clock = 0.0
    var gpu: [Double] = [], cpu: [Double] = [], crashMs: [Double] = []
    var driver: (Float) -> DriverInput = { _ in DriverInput() }
    let base: String?

    init?(_ o: Options) {
        guard let device = MTLCreateSystemDefaultDevice() else { fputs("sin GPU Metal\n", stderr); return nil }
        self.device = device
        let (root, tried) = DataLocator.locate(arg: o.data, disc: o.disc)
        guard let root, let data = try? GameData(root: root) else { fputs("No encuentro datos. Buscado en:\n\(tried.joined(separator: "\n"))\n", stderr); return nil }
        guard let e = try? Engine(device: device, data: data, outputFormat: .bgra8Unorm) else { return nil }
        engine = e
        guard let ai = e.ai, let crash = ai.crash else { fputs("sin IA o sin choques (faltan roads.json/ai.json o --no-crash)\n", stderr); return nil }
        self.ai = ai; self.crash = crash
        if !o.noUI, let ui = e.enableUI(outputFormat: .bgra8Unorm) { ui.startHUDOnly() }
        let (W, H) = o.size
        e.aspect = Float(W) / Float(H)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]; td.storageMode = .private
        target = device.makeTexture(descriptor: td)!
        base = o.screenshot.map { ($0 as NSString).deletingPathExtension }
        e.driverFilter = { [weak self] d, reset, dt in
            guard let self else { return }
            d = self.driver(dt); reset = false
        }
    }

    @discardableResult
    func frame(_ dt: Float = 1.0 / 60) -> Double {
        clock += Double(dt)
        let c0 = CACurrentMediaTime()
        let cb = engine.queue.makeCommandBuffer()!
        engine.frame(cb: cb, target: target, dt: dt, scale: 1, now: clock)
        cb.commit()
        let c = (CACurrentMediaTime() - c0) * 1000
        cb.waitUntilCompleted()
        if dt > 0 { gpu.append((cb.gpuEndTime - cb.gpuStartTime) * 1000); cpu.append(c); crashMs.append(crash.lastCost) }
        return c
    }

    /// Espera a que carguen las casillas y los modelos alrededor de la cámara.
    func load(_ seconds: Double = 120) {
        let l0 = CACurrentMediaTime()
        while true {
            frame(0)
            let s = engine.streamer.stats
            if engine.streamer.allFarLoaded && engine.streamer.idle && s.nearReady == s.near && ai.models.allIdle && (crash.renderer?.idle ?? true) { break }
            if CACurrentMediaTime() - l0 > seconds { break }
            usleep(5000)
        }
    }

    func shot(_ name: String) {
        guard let b = base else { return }
        writePNG(target, device: device, queue: engine.queue, path: "\(b)-\(name).png")
    }

    /// Tramo recto real de al menos `length` m cerca de p: punto inicial, dirección y anchos de carril.
    func straight(near p: float3, length: Float) -> (start: float3, dir: float3, seg: Int)? {
        let net = ai.net
        var cands: [(Int, Float)] = []
        for i in 0..<net.count where net.trafficAllowed(i) && !net.segs[i].has(RoadSegFlags.decision) && net.segs[i].length >= length {
            let d = simd_distance(net.point(i, 0.5), p)
            if d < 1500 { cands.append((i, d)) }
        }
        for (i, _) in cands.sorted(by: { $0.1 < $1.1 }) {
            let t0 = net.tangent(i, 0.05), t1 = net.tangent(i, 0.95)
            guard simd_dot(simd_normalize(t0), simd_normalize(t1)) > 0.995 else { continue }
            let a = net.point(i, 0.05), b = net.point(i, 0.95)
            if abs(a.z - b.z) > length * 0.04 { continue }
            if ai.collision.hitsWall(from: a + float3(0, 0, 0.5), to: b + float3(0, 0, 0.5)) { continue }
            return (a, simd_normalize(float3(b.x - a.x, b.y - a.y, 0)), i)
        }
        return nil
    }

    func clearAI() {
        for v in ai.vehicles { ai.remove(v) }
        ai.vehicles.removeAll()
    }

    func makeAI(_ model: String, type: String, kind: AIVehicle.Kind, at p: float3, yaw: Float) -> AIVehicle? {
        ai.models.preload([model])
        let t0 = CACurrentMediaTime()
        while ai.models.model(model) == nil && CACurrentMediaTime() - t0 < 30 { usleep(10000) }
        guard let m = ai.models.model(model) else { return nil }
        let v = AIVehicle(id: ai.newID(), kind: kind, model: m, typeName: type)
        v.pos = p; v.yaw = yaw; v.mode = .parked; v.speed = 0
        if let g = ai.collision.ground(x: p.x, y: p.y, z: p.z + 2, step: 3) { v.pos.z = g.z }
        ai.vehicles.append(v)
        return v
    }

    /// Penetración máxima entre los volúmenes de dos cuerpos (comprobación de «sin solapes»).
    func maxPenetration() -> Float {
        var worst: Float = 0
        for ev in crash.events {
            ev.a.refresh(); ev.b.refresh()
            for pa in ev.a.prims { for pb in ev.b.prims { if let c = CrashGeometry.intersect(pa, pb) { worst = max(worst, c.depth) } } }
        }
        return worst
    }
}

/// Piloto del jugador: gas a fondo hasta `kmh`, dirección hacia un punto (o recto).
private func autopilot(_ car: Car, kmh: Float, toward: float3?) -> DriverInput {
    var d = DriverInput()
    let v = car.kmh
    d.gas = v < kmh ? 1 : (v < kmh + 5 ? 0.3 : 0)
    if let t = toward {
        let to = simd_normalize(float2(t.x - car.position.x, t.y - car.position.y) + 1e-6)
        let f = simd_normalize(float2(car.forward.x, car.forward.y) + 1e-6)
        let cross = f.x * to.y - f.y * to.x
        let s = max(-1, min(1, cross * 2.5))
        d.steerLeft = max(s, 0); d.steerRight = max(-s, 0)
    }
    return d
}

func runCrashTest(_ o: Options, scenario: String) {
    guard let rig = CrashTestRig(o) else { exit(1) }
    let e = rig.engine, ai = rig.ai, crash = rig.crash
    AIConfig.maxTraffic = 0
    AIConfig.police = false
    e.loadCar()
    guard let car = e.car else { fputs("sin coche del jugador\n", stderr); exit(1) }
    var start = e.camPos
    if let z = e.data.zones.first(where: { $0.zoneType == "safehouse" }), let r = z.respawn, r.position.count == 3 { start = float3(r.position[0], r.position[1], r.position[2]) }
    if let c = o.camera, c.count >= 3 { start = float3(c[0], c[1], c[2]) }
    let all = ["frontal", "lateral", "pit", "rompibles", "derrumbe", "rendimiento"]
    let list = scenario == "all" ? all : scenario.split(separator: ",").map(String.init)
    var results: [String: Any] = [:]
    _ = SFXWorld.shared.prepare(root: e.data.root, outRate: 48000)   // stitches de golpe (sin salida de audio)
    print("Prueba de choques: \(list.joined(separator: ", ")) · \(crash.data.carBounds.count) coches con volúmenes, \(crash.smackables.all.count) rompibles")

    func reset(_ p: float3, yaw: Float) {
        rig.clearAI()
        e.mode = .drive
        car.place(p, yaw: yaw, collision: e.collision)
        car.repairDamage()
        crash.events.removeAll()
        crash.log.removeAll()
        ai.police.heat = 1
    }
    func run(_ seconds: Float, each: (Int) -> Void = { _ in }) -> (impacts: Int, maxImpulse: Float, maxPen: Float, events: Int) {
        var impacts = 0, maxJ: Float = 0, maxPen: Float = 0, evs = 0
        let n = Int(seconds * 60)
        for i in 0..<n {
            each(i)
            rig.frame()
            if !crash.events.isEmpty {
                evs += crash.events.count
                maxJ = max(maxJ, crash.events.map(\.impulse).max() ?? 0)
                maxPen = max(maxPen, rig.maxPenetration())
                impacts += crash.events.filter { $0.closing > 1 }.count
            }
        }
        return (impacts, maxJ, maxPen, evs)
    }

    guard let road = rig.straight(near: start, length: 140) else { fputs("no hay un tramo recto cerca\n", stderr); exit(1) }
    let roadYaw = atan2(road.dir.y, road.dir.x)
    let side = float3(road.dir.y, -road.dir.x, 0)
    print(String(format: "Tramo recto: segmento %d desde (%.0f, %.0f, %.0f) rumbo %.0f°", road.seg, road.start.x, road.start.y, road.start.z, roadYaw * 180 / .pi))
    e.camPos = road.start
    reset(road.start, yaw: roadYaw)
    rig.load()

    for sc in list {
        crash.log.removeAll()
        var r: [String: Any] = ["scenario": sc]
        switch sc {
        case "frontal":
            reset(road.start + side * 1.5, yaw: roadYaw)
            guard let t = rig.makeAI("TRAF4DSEDA", type: "traf4dseda", kind: .traffic, at: road.start + road.dir * 110 + side * 1.5, yaw: roadYaw + .pi) else { break }
            rig.load(20)
            t.speed = 14; t.mode = .free; t.target = t.pos - road.dir * 300
            rig.driver = { _ in autopilot(car, kmh: 90, toward: nil) }
            var hitAt: Int?, carV0: Float = 0, carV1: Float = 0, trafficSpinPeak: Float = 0
            let res = run(7) { i in
                if hitAt == nil { t.target = car.position }   // de cara al jugador hasta el golpe
                if t.mode == .free && !t.dyn { t.driveFree(collision: ai.collision, dt: 1.0 / 60, mu: 0.6) }
                else if t.dyn { t.stepDynamic(collision: ai.collision, dt: 1.0 / 60) }
                if hitAt == nil, !crash.events.isEmpty { hitAt = i; rig.shot("frontal-1-golpe") }
                if let h = hitAt, i == h + 15 { carV1 = car.kmh }
                if hitAt == nil { carV0 = car.kmh }
                trafficSpinPeak = max(trafficSpinPeak, abs(t.yawRate))
                if let h = hitAt, i == h + 45 { rig.shot("frontal-2-despues") }
            }
            rig.shot("frontal-3-final")
            r["impacts"] = res.impacts; r["maxImpulseNs"] = res.maxImpulse; r["maxPenetrationM"] = res.maxPen
            r["playerKmhBefore"] = carV0; r["playerKmhAfterHit"] = carV1; r["trafficDynamic"] = t.dyn || t.crashed; r["trafficYawRatePeak"] = trafficSpinPeak
            r["playerDamageZones"] = car.damage.zones
        case "lateral":
            reset(road.start + side * 1.5, yaw: roadYaw)
            guard let c = rig.makeAI("COPMIDSIZE", type: "copmidsize", kind: .cop, at: road.start + road.dir * 90 + side * 1.5, yaw: roadYaw + .pi / 2) else { break }
            c.copRole = .roadblock
            rig.load(20)
            rig.driver = { _ in autopilot(car, kmh: 100, toward: c.pos) }
            var firstHit: Int?
            var res = run(5) { i in
                if c.dyn { c.stepDynamic(collision: ai.collision, dt: 1.0 / 60) }
                if firstHit == nil, !crash.events.isEmpty { firstHit = i; rig.shot("lateral-1-golpe") }
                if let h = firstHit, i == h + 30 { rig.shot("lateral-2-panel") }
            }
            r["hit1"] = ["copZones": c.damage.zones, "copLife": c.damage.total, "brokenPanels": c.damage.brokenSlots.nonzeroBitCount, "destroyed": c.damage.destroyed,
                         "impulse": res.maxImpulse, "maxPenetrationM": res.maxPen]
            // Más embestidas iguales (el policía vuelve a su sitio con sus daños) hasta destruirlo
            let copHome = road.start + road.dir * 90 + side * 1.5
            var rams = 1
            while !c.damage.destroyed && rams < 4 {
                rams += 1
                c.dyn = false; c.dynVel = .zero; c.yawRate = 0; c.pos = copHome; c.yaw = roadYaw + .pi / 2
                if let g = ai.collision.ground(x: copHome.x, y: copHome.y, z: copHome.z + 2, step: 3) { c.pos.z = g.z }
                car.place(road.start + side * 1.5, yaw: roadYaw, collision: e.collision)
                rig.driver = { _ in autopilot(car, kmh: 110, toward: c.pos) }
                res = run(5) { _ in if c.dyn { c.stepDynamic(collision: ai.collision, dt: 1.0 / 60) } }
            }
            r["rams"] = rams
            e.carCam = (float3(-9, 6, 4), float3(6, 0, 0.5))
            rig.frame(); rig.shot("lateral-3-destruido")
            e.carCam = nil
            r["hit2"] = ["copZones": c.damage.zones, "copLife": c.damage.total, "brokenPanels": c.damage.brokenSlots.nonzeroBitCount, "destroyed": c.damage.destroyed,
                         "impulse": res.maxImpulse, "maxPenetrationM": res.maxPen]
            r["playerDamageZones"] = car.damage.zones
            r["statsCopsDestroyed"] = ai.stats.copsDestroyed
        case "pit":
            reset(road.start + side * 1.5, yaw: roadYaw)
            guard let c = rig.makeAI("COPGTO", type: "copgto", kind: .cop, at: road.start - road.dir * 25 - side * 2.0, yaw: roadYaw) else { break }
            c.copRole = .pursuit; c.lights = true
            rig.load(20)
            rig.driver = { _ in autopilot(car, kmh: 100, toward: car.position + road.dir * 50 + side * 0) }
            var yaw0: Float = 0, yawPeak: Float = 0, spinPeak: Float = 0, hit: Int?
            let res = run(8) { i in
                // Policía: al hueco de la aleta trasera izquierda y luego hacia dentro (PIT: embiste a 4 s de formación) [D: P:179-439]
                if !c.dyn {
                    let pf = car.forward, pr = float3(pf.y, -pf.x, 0)
                    let along = simd_dot(c.pos - car.position, pf)
                    let rearQuarter = car.position - pf * 1.4 - pr * (along < -3.5 ? 2.4 : -0.6)
                    c.mode = .free; c.target = rearQuarter + car.velocity * 0.25
                    let want = max(0, simd_dot(car.velocity, c.fwd)) + max(-8, min(14, simd_dot(c.target - c.pos, c.fwd) * 1.2))
                    c.speed += max(-14 / 60, min(10 / 60, want - c.speed))
                    c.driveFree(collision: ai.collision, dt: 1.0 / 60, mu: 1.6)
                } else { c.stepDynamic(collision: ai.collision, dt: 1.0 / 60) }
                if i == 100 { yaw0 = car.yaw }
                if hit == nil, !crash.events.isEmpty, i > 60 { hit = i; rig.shot("pit-1-golpe") }
                if let h = hit, i == h + 40 { rig.shot("pit-2-trompo") }
                if i > 100 { yawPeak = max(yawPeak, abs(angleDiff(car.yaw, yaw0))) }
                if let v = car.vehicle { spinPeak = max(spinPeak, abs(v.rb.angularVel.y)) }
            }
            r["impacts"] = res.impacts; r["maxImpulseNs"] = res.maxImpulse; r["maxPenetrationM"] = res.maxPen
            r["playerHeadingChangeDeg"] = yawPeak * 180 / .pi; r["playerYawRatePeak"] = spinPeak
            r["playerDamageZones"] = car.damage.zones
        case "rompibles":
            // La fila de rompibles más cercana al recorrido: los que quedan a ±3 m de una recta de 120 m por un tramo
            var best: (p: float3, d: float3, list: [Smackable])?
            for i in 0..<ai.net.count where ai.net.trafficAllowed(i) && ai.net.segs[i].length > 60 {
                let a = ai.net.point(i, 0), b = ai.net.point(i, 1)
                if simd_distance(a, start) > 900 { continue }
                let dir = simd_normalize(float3(b.x - a.x, b.y - a.y, 0) + 1e-6)
                for off in [-6, -4.5, 4.5, 6] as [Float] {
                    let sd = float3(dir.y, -dir.x, 0) * off
                    var l: [Smackable] = []
                    crash.smackables.near(a + sd + dir * 30, radius: 40, into: &l)
                    let line = l.filter { s in
                        let rel = s.pos - (a + sd); let along = simd_dot(rel, dir); let across = abs(simd_dot(rel, float3(dir.y, -dir.x, 0)))
                        return along > 10 && along < 70 && across < 1.5 && s.state == .attached && s.type.detachForce >= 0 && s.type.detachForce < 8000
                    }
                    if line.count > (best?.list.count ?? 1) { best = (a + sd, dir, line) }
                }
            }
            guard let b = best else { r["error"] = "sin rompibles en línea"; break }
            reset(b.p, yaw: atan2(b.d.y, b.d.x))
            rig.load(30)
            let target = b.p + b.d * 90
            rig.driver = { _ in autopilot(car, kmh: 80, toward: target) }
            var first: Int?
            let res = run(6) { i in
                if first == nil, !crash.events.isEmpty { first = i }
                if let f = first, i == f + 20 { rig.shot("rompibles-1") }
                if let f = first, i == f + 70 { rig.shot("rompibles-2") }
            }
            rig.shot("rompibles-3-final")
            let knocked = b.list.filter { $0.state != .attached }
            r["inLine"] = b.list.count; r["knocked"] = knocked.count; r["types"] = Array(Set(b.list.map(\.type.name)))
            r["impacts"] = res.impacts; r["maxImpulseNs"] = res.maxImpulse; r["playerKmhEnd"] = car.kmh
            r["smackablesHit"] = ai.stats.smackablesHit
        case "derrumbe":
            guard let br = crash.breakers.list.sorted(by: { simd_distance($0.pos, start) < simd_distance($1.pos, start) })
                    .first(where: { b in b.members.contains { $0.type.detachForce >= 0 && $0.type.detachForce < 5000 } }),
                  let trig = br.members.filter({ $0.type.detachForce >= 0 }).min(by: { $0.type.detachForce < $1.type.detachForce }) else { r["error"] = "sin derrumbe"; break }
            // Arranque a 60 m del soporte, de cara a él
            var dir = trig.pos - br.pos; dir.z = 0
            if simd_length(dir) < 3 { dir = float3(1, 0, 0) }
            dir = simd_normalize(dir)
            let from = trig.pos + dir * 55
            reset(from, yaw: atan2(-dir.y, -dir.x))
            AIConfig.police = true
            ai.police.heat = 3
            rig.load(30)
            // Dos policías al lado del marcador (parados, «control») y persecución activa
            var cops: [AIVehicle] = []
            for k in 0..<2 {
                let p = br.pos + float3(Float(k) * 6 - 3, 4, 0)
                if let c = rig.makeAI("COPMIDSIZE", type: "copmidsize", kind: .cop, at: p, yaw: Float(k) * 1.3) { c.copRole = .roadblock; c.lights = true; cops.append(c) }
            }
            rig.frame(); ai.police.forcePursuit()
            rig.load(20)
            e.camPos = from
            rig.driver = { _ in autopilot(car, kmh: 70, toward: trig.pos) }
            var trigAt: Int?
            let res = run(8) { i in
                if trigAt == nil, br.triggered { trigAt = i; rig.shot("derrumbe-1") }
                if let t = trigAt, i == t + 50 { rig.shot("derrumbe-2") }
                if let t = trigAt, i == t + 120 { rig.shot("derrumbe-3") }
            }
            r["breaker"] = br.name; r["members"] = br.members.count; r["trigger"] = trig.type.name; r["triggered"] = br.triggered
            r["fallen"] = br.members.filter { $0.state != .attached && $0.state != .loose }.count
            r["copsImmobilized"] = cops.filter { $0.damage.destroyed }.count
            r["hudCopsDestroyed"] = ai.police.copsDestroyed; r["costToState"] = ai.police.costToState
            r["impacts"] = res.impacts
            AIConfig.police = false
        case "rendimiento":
            reset(road.start + side * 1.5, yaw: roadYaw)
            AIConfig.maxTraffic = 22; AIConfig.police = true
            ai.police.heat = 4
            rig.driver = { _ in autopilot(car, kmh: 70, toward: nil) }
            rig.gpu.removeAll(); rig.cpu.removeAll(); rig.crashMs.removeAll()
            var peak = 0
            let res = run(25) { _ in peak = max(peak, ai.vehicles.count) }
            rig.shot("rendimiento")
            r["maxCars"] = peak + 1; r["events"] = res.events
            r["crashStepMedianMs"] = median(rig.crashMs); r["crashStepP95Ms"] = pct(rig.crashMs, 0.95)
            r["cpuMedianMs"] = median(rig.cpu); r["gpuMedianMs"] = median(rig.gpu)
            AIConfig.maxTraffic = 0; AIConfig.police = false
        default:
            r["error"] = "escenario desconocido"
        }
        r["log"] = crash.log.suffix(30)
        results[sc] = r
        let summary = r.filter { $0.key != "log" }.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " · ")
        print("— \(sc): \(summary)")
    }
    print(String(format: "Coste de los choques: mediana %.3f ms, p95 %.3f ms por fotograma", median(rig.crashMs), pct(rig.crashMs, 0.95)))
    if let b = rig.base, let d = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
        try? d.write(to: URL(fileURLWithPath: b + "-crash.json"))
        print("Resultados: \(b)-crash.json")
    }
    exit(0)
}

func runHeliTest(_ o: Options, seconds: Double) {
    guard let rig = CrashTestRig(o) else { exit(1) }
    let e = rig.engine, ai = rig.ai
    guard let hm = ai.heli else { fputs("sin helicóptero (--no-heli)\n", stderr); exit(1) }
    ai.police.heat = Float(AIOptions.value("--heat").flatMap(Float.init) ?? 5)
    hm.forceSpawn = true
    var start = e.camPos
    if let z = e.data.zones.first(where: { $0.zoneType == "safehouse" }), let r = z.respawn, r.position.count == 3 { start = float3(r.position[0], r.position[1], r.position[2]) }
    ai.models.preload([Config.playerCar, "COPHELI"])
    let t0 = CACurrentMediaTime()
    while (!ai.models.allIdle || ai.models.model(Config.playerCar) == nil) && CACurrentMediaTime() - t0 < 60 { usleep(20000) }
    guard let pm = ai.models.model(Config.playerCar),
          let hit = ai.net.nearest(start, maxDist: 300, filter: { ai.net.trafficAllowed($0) && !ai.net.segs[$0].has(RoadSegFlags.decision) }) else { exit(1) }
    let pv = AIVehicle(id: 0, kind: .traffic, model: pm, typeName: "player")
    pv.place(net: ai.net, seg: hit.seg, forward: true, t: hit.t, lane: 0, collision: ai.collision)
    AITestDriver.plan = "run"
    let driver = AITestDriver(v: pv, duration: Float(seconds))
    AITestDriver.current = driver
    e.aiRenderer?.extraVehicles = [pv]
    e.camPos = pv.pos
    rig.load()
    var log: [String] = []
    var seenFrames = 0, heliFrames = 0, minD: Float = 1e9, maxD: Float = 0, sumD: Float = 0
    let n = Int(seconds * 60)
    var shots = Set<Int>()
    var forced = false
    for i in 0..<n {
        driver.step(ai, dt: 1.0 / 60)
        if !forced && i > 30 { ai.police.forcePursuit(); forced = true }
        // Cámara: detrás del coche; si hay helicóptero, mirando hacia él
        let f = pv.fwd
        e.camPos = pv.pos - f * 11 + float3(0, 0, 4.5)
        if let h = hm.heli {
            let d = simd_normalize(h.pos - e.camPos)
            e.yaw = atan2(d.y, d.x); e.pitch = max(-0.3, min(0.9, asin(d.z)))
        } else { e.yaw = pv.yaw; e.pitch = -0.15 }
        rig.frame()
        if let h = hm.heli {
            heliFrames += 1
            if h.seesPlayer { seenFrames += 1 }
            let d = simd_distance(h.pos, pv.pos)
            minD = min(minD, d); maxD = max(maxD, d); sumD += d
            if i % 120 == 0 {
                log.append(String(format: "%.0f s: modo %@ · %.0f m del jugador · altura %.0f m sobre él · ve %@ · combustible %.0f s · calor %.2f",
                                  Double(i) / 60, "\(h.mode)", d, h.pos.z - pv.pos.z, h.seesPlayer ? "sí" : "no", h.fuel, ai.police.heat))
            }
            let near = heliFrames == 240 || heliFrames == 900
            if near && !shots.contains(heliFrames) { shots.insert(heliFrames); rig.shot("heli-\(heliFrames / 60)s") }
        }
    }
    rig.shot("heli-final")
    for l in hm.log + log { print("  " + l) }
    let res: [String: Any] = ["seconds": seconds, "spawned": hm.spawnedCount, "heliSeconds": Double(heliFrames) / 60,
                              "lineOfSightPct": heliFrames > 0 ? 100 * Double(seenFrames) / Double(heliFrames) : 0,
                              "distanceMin": minD, "distanceMax": maxD, "distanceMean": heliFrames > 0 ? sumD / Float(heliFrames) : 0,
                              "pursuitState": "\(ai.police.state)", "costToState": ai.police.costToState, "log": hm.log + log,
                              "gpuMedianMs": median(rig.gpu), "cpuMedianMs": median(rig.cpu)]
    print("— helicóptero: " + res.filter { $0.key != "log" }.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " · "))
    if let b = rig.base, let d = try? JSONSerialization.data(withJSONObject: res, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: URL(fileURLWithPath: b + "-heli.json")) }
    exit(0)
}
