// Pruebas sin ventana de los efectos (Effects/):
//   Rockport --fx-test burnout --screenshot base.png [--size WxH] [--frames N]
//       el coche del jugador en la calle del refugio 1: quemada parado (gas + freno) y salida con nitro; capturas base-quemada.png,
//       base-nitro.png y estadísticas (partículas, destellos, GPU con y sin efectos).
//   Rockport --fx-test street --screenshot base.png [--cam x,y,z,rumbo,inclinación]
//       cámara junto al grupo de semáforos más denso del mapa (o --cam), con tráfico; captura y estadísticas.
//   Rockport --fx-test pursuit --screenshot base.png   tres patrullas con la barra de luces detrás del coche (destellos)
//   Rockport --fx-test stats   cuenta lo que hay en effects.json y prueba las curvas de los emisores (sin GPU de dibujo).
// Las escenas de menú y garajes se capturan con las pruebas de siempre (--ui-test MainMenu, --garage-scene, --garage-test):
// los efectos van enganchados al motor.
import Foundation
import Metal
import QuartzCore
import simd

enum EffectsTests {
    static func handle(_ args: [String]) -> Bool {
        guard let i = args.firstIndex(of: "--fx-test"), i + 1 < args.count else { return false }
        let kind = args[i + 1]
        let o = Options.parse(args)
        run(o, kind: kind)
        return true
    }

    private static func run(_ o: Options, kind: String) {
        guard let device = MTLCreateSystemDefaultDevice() else { fputs("sin GPU Metal\n", stderr); exit(1) }
        let (root, tried) = DataLocator.locate(arg: o.data, disc: o.disc)
        guard let root, let data = try? GameData(root: root) else { fputs("No encuentro datos. Buscado en:\n\(tried.joined(separator: "\n"))\n", stderr); exit(1) }
        if kind == "stats" { stats(data); return }
        guard let engine = try? Engine(device: device, data: data, outputFormat: .bgra8Unorm) else { fputs("motor\n", stderr); exit(1) }
        guard let fx = engine.renderer.effects else { fputs("efectos no disponibles (falta effects.json o ROCKPORT_FX=0)\n", stderr); exit(1) }
        let (W, H) = o.size
        engine.aspect = Float(W) / Float(H)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]; td.storageMode = .private
        let target = device.makeTexture(descriptor: td)!
        var clock = 0.0
        @discardableResult func render(_ n: Int, dt: Float = 1.0 / 60) -> [Double] {
            var gpu: [Double] = []
            for _ in 0..<n {
                clock += Double(dt)
                let cb = engine.queue.makeCommandBuffer()!
                engine.frame(cb: cb, target: target, dt: dt, scale: o.scale ?? 1, now: clock)
                cb.commit(); cb.waitUntilCompleted()
                gpu.append((cb.gpuEndTime - cb.gpuStartTime) * 1000)
            }
            return gpu
        }
        func load() {
            let t0 = CACurrentMediaTime()
            while true {
                render(1)
                let s = engine.streamer.stats
                if engine.streamer.allFarLoaded && engine.streamer.idle && s.nearReady == s.near && clock > 0.5 { break }
                if CACurrentMediaTime() - t0 > 120 { break }
                usleep(5000)
            }
        }
        let base = o.screenshot.map { ($0 as NSString).deletingPathExtension }
        func shot(_ s: String) { if let b = base { writePNG(target, device: device, queue: engine.queue, path: "\(b)-\(s).png") } }
        func measure(_ label: String) {
            let on = render(max(30, o.frames))
            EffectsSystem.enabled = false
            let saved = engine.renderer.overlays
            engine.renderer.overlays = saved.filter { !($0 is EffectsSystem) }
            let off = render(max(30, o.frames), dt: 0)
            engine.renderer.overlays = saved
            EffectsSystem.enabled = true
            print(String(format: "%@: GPU med %.2f ms (sin efectos %.2f) · %d partículas · %d destellos · %d grupos vivos",
                         label, median(on), median(off), fx.lastParticles, fx.lastFlares, fx.particles.groups.count))
        }

        switch kind {
        case "burnout":
            engine.loadCar()
            guard let car = engine.car else { fputs("sin coche\n", stderr); exit(1) }
            engine.mode = .drive
            load()
            // Quemada parado (gas + freno: las ruedas de atrás patinan a ~22 m/s) y luego salida con nitro
            engine.keys = [Key.w.rawValue, Key.s.rawValue]
            for i in 0..<150 {
                render(1)
                if i % 30 == 0 { print(String(format: "  %d: %.0f km/h · patinaje %.1f m/s · partículas %d", i, car.kmh, car.vehicle?.susp.tires[2].slip ?? 0, fx.particles.totalParticles)) }
            }
            engine.carCam = (float3(-5.5, 3.2, 1.3), float3(-0.8, 0, 0.5))
            render(1)
            shot("quemada")
            measure("Quemada")
            engine.carCam = nil
            engine.keys = [Key.w.rawValue, 45]   // N = nitro
            render(45)
            engine.carCam = (float3(-2.2, -3.6, 0.9), float3(0.2, -0.8, 0.25))   // escapes laterales del M3 GTR (lado derecho)
            render(1)
            print(String(format: "nitro: %.0f km/h · %@", car.kmh, car.isNOSEngaged ? "nitro encendido" : "sin nitro"))
            shot("nitro")
            measure("Nitro")
        case "street":
            engine.loadCar()
            if let c = o.camera, c.count == 5 {
                engine.setCamera(x: c[0], y: c[1], z: c[2], yawDeg: c[3], pitchDeg: c[4])
            } else if let car = engine.car, let net = engine.ai?.net {
                // Cruce con más semáforos (destellos ámbar/rojo/verde, radio 60 m); el coche en la calle 45 m antes, mirándolos
                let lights = fx.library.flares.filter { (17...19).contains($0.type) }
                var best = (n: 0, p: float3.zero)
                for f in lights {
                    let n = lights.filter { simd_distance_squared($0.pos, f.pos) < 60 * 60 }.count
                    if n > best.n { best = (n, f.pos) }
                }
                let near = lights.filter { simd_distance_squared($0.pos, best.p) < 60 * 60 }
                let c = near.reduce(float3.zero) { $0 + $1.pos } / Float(max(near.count, 1))
                if let h = net.nearest(c, maxDist: 80) {
                    let seg = net.segs[h.seg]
                    let back = max(0, h.t - 45 / max(seg.length, 1))
                    let p = net.point(h.seg, back), q = net.point(h.seg, min(1, back + 0.05))
                    let d = simd_normalize(float3(q.x - p.x, q.y - p.y, 0) + float3(1e-4, 0, 0))
                    car.place(p + float3(0, 0, 1), yaw: atan2(d.y, d.x), collision: engine.collision)
                    engine.mode = .drive
                    engine.carCam = (float3(-7, 0.6, 2.2), float3(12, 0, 3))
                }
                print("calle: \(best.n) semáforos cerca de \(c)")
            }
            load()
            render(240)
            for _ in 0..<60 where !(fx.flares.blink[0] && fx.flares.blink[2]) { render(1) }   // con los intermitentes encendidos
            shot("calle")
            measure("Calle")
        case "pursuit":
            // Tres patrullas con la barra de luces encendida detrás del coche del jugador, vistas desde delante
            engine.loadCar()
            guard let car = engine.car, let ai = engine.ai, let air = engine.aiRenderer else { fputs("sin coche o sin IA\n", stderr); exit(1) }
            if let c = o.camera, c.count >= 3 { car.place(float3(c[0], c[1], c[2]), yaw: c.count > 3 ? c[3] * .pi / 180 : 0, collision: engine.collision) }
            engine.mode = .drive
            let copModel = "COPMIDSIZE"
            ai.models.preload([copModel])
            let t0 = CACurrentMediaTime()
            while ai.models.model(copModel) == nil && CACurrentMediaTime() - t0 < 30 { usleep(20000) }
            guard let m = ai.models.model(copModel) else { fputs("sin modelo de policía\n", stderr); exit(1) }
            let fwd = car.forward, left = float3(-fwd.y, fwd.x, 0)
            for (k, off) in [float2(-9, 1.6), float2(-16, -1.8), float2(-24, 1.2)].enumerated() {
                let v = AIVehicle(id: 900 + k, kind: .cop, model: m, typeName: "copmidsize")
                var p = car.position + fwd * off.x + left * off.y
                if let g = engine.collision.ground(x: p.x, y: p.y, z: p.z + 2) { p.z = g.z }
                v.pos = p; v.yaw = car.yaw; v.lights = true; v.mode = .parked
                air.extraVehicles.append(v)
            }
            engine.carCam = (float3(5.5, -2.2, 1.7), float3(-14, 0.5, 1.0))
            load()
            render(90)
            shot("persecucion")
            measure("Persecución")
        default:
            fputs("--fx-test: burnout | street | pursuit | stats\n", stderr); exit(1)
        }
        exit(0)
    }

    /// Sin dibujo: cuenta datos y comprueba que las curvas de los emisores dan valores con sentido.
    private static func stats(_ data: GameData) {
        guard let lib = EffectsLibrary.shared(data) else { fputs("sin effects.json\n", stderr); exit(1) }
        var singular = 0, neg = 0
        for e in lib.emitters {
            if e.colour.linear != nil { singular += 1 }
            for k in 0...20 { let v = e.extra.eval(Float(k) / 20); if v.x < -0.01 { neg += 1; break } }
        }
        print("emisores \(lib.emitters.count) · curvas singulares \(singular) · tamaños negativos en algún punto \(neg)")
        let ps = ParticleSystem(library: lib)
        for name in ["fxenv_fog_fe1", "fxtd_sk_asphalt", "fxcar_nos", "fxenv_small_steam2", "fxcar_impactl"] {
            guard let g = ps.makeGroup(name, flags: [.alwaysClose]) else { print("\(name): no existe"); continue }
            g.autoUpdate = true
            for _ in 0..<120 { ps.update(dt: 1.0 / 60) }
            print("\(name): \(g.particleCount) partículas tras 2 s")
            ps.remove(g)
        }
        exit(0)
    }
}
