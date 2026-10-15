// Efectos del juego en el motor nativo (doc 20 §9, doc 24): partículas (Particles.swift), destellos (LightFlares.swift), niebla y
// tinte por zona (ZoneFog.swift) y haces de luz de las ventanas de los garajes conducibles (GarageShafts.swift).
// Se engancha como una capa más del Renderer (RenderOverlay): simula una vez por fotograma (en la primera vista) y dibuja en
// cada vista, dentro de la pasada de escena y en el espacio de color del PS2 (sceneRGB / ps2Encode, doc 20 §2):
//   - partículas de mezcla normal ordenadas de lejos a cerca y aditivas, billboards instanciados (una llamada por tipo) con todas
//     las texturas de partícula del disco en un array de texturas (46 × 64², 0,8 MB);
//   - destellos aditivos de cara a la cámara (HEADLIGHTGLOW / HEADLIGHTFLAREOUTER / HEADLIGHTFLAREINNER) en una llamada.
import Foundation
import Metal
import simd

/// Instancia de partícula para la GPU (`PInst` de MSL).
struct ParticleInstance {
    var posSize: float4      // xyz mundo, w medio lado (m)
    var colour: float4       // RGBA en la escala del GS (1 = 128)
    var uv: float4           // u0 v0 u1 v1
    var misc: float4         // x giro (rad), y capa del array, z restricción de eje, w aditiva
}

final class EffectsSystem: RenderOverlay {
    unowned let engine: Engine
    let library: EffectsLibrary
    let particles: ParticleSystem
    let carFX: CarEffects
    let flares: LightFlares
    let zone: ZoneFog
    let shafts: GarageShafts
    private let gpu: EffectsGPU
    private(set) var drawCalls = 0
    /// Estadísticas del último fotograma (pruebas): partículas, destellos dibujados.
    private(set) var lastParticles = 0, lastFlares = 0

    // Fotograma
    private var lastFrame = -1
    private var lastTime: Float?
    private var lastWall = CFAbsoluteTimeGetCurrent()
    private var camerasThisFrame: [(pos: float3, dir: float3)] = []
    private var firstFrame = true
    // Emisores del garaje (frontend o garaje del mundo abierto)
    private var feKey: String?
    private var feModel = float4x4.identity
    private var feGroups: [EmitterGroup] = []

    /// Fuerza del tinte de zona en el tono PS2 (0,3: con 219, 206, 87 da casi el ámbar fijo de antes) [I].
    static var screenTintStrength: Float = 0.3
    /// Apagar (depuración / comparar): ROCKPORT_FX=0.
    static var enabled = ProcessInfo.processInfo.environment["ROCKPORT_FX"] != "0"

    @discardableResult
    static func attach(_ engine: Engine) -> EffectsSystem? {
        guard enabled, let lib = EffectsLibrary.shared(engine.data) else { return nil }
        guard let gpu = try? EffectsGPU(device: engine.device, queue: engine.queue, textures: engine.textures, library: lib) else {
            fputs("efectos: sin shaders\n", stderr); return nil
        }
        let s = EffectsSystem(engine: engine, library: lib, gpu: gpu)
        engine.renderer.overlays.append(s)
        engine.renderer.effects = s
        AIRenderer.externalFlares = true   // los destellos de la barra de luces los pone esta capa
        return s
    }

    private init(engine: Engine, library: EffectsLibrary, gpu: EffectsGPU) {
        self.engine = engine; self.library = library; self.gpu = gpu
        particles = ParticleSystem(library: library)
        carFX = CarEffects(particles: particles, data: engine.data)
        flares = LightFlares(data: engine.data, world: library.flares)
        zone = ZoneFog(library: library)
        shafts = GarageShafts(engine: engine)
    }

    // MARK: Contexto

    /// ¿Se ve el escenario del frontend (sin ciudad)?
    private var inFrontEnd: Bool { engine.garages?.stage.active ?? false }

    /// Interior del garaje a la vista y su matriz (interior → mundo).
    private func garageContext() -> (key: String, model: float4x4)? {
        guard let gs = engine.garages else { return nil }
        if gs.stage.active {
            let k = gs.stage.kind
            return (k.interior, float4x4(translation: FEStage.origin + float3(0, k.geometryY, 0)) * float4x4(rotationZ: k.geometryZAngle * .pi / 180))
        }
        if GarageCutout.active, let g = gs.world?.current { return (g.interior, g.interiorModel) }
        return nil
    }

    /// Coches con física: jugador, rivales de carrera y jugadores de la pantalla partida.
    private func physicsCars() -> [Car] {
        var out: [Car] = []
        func add(_ c: Car?) { if let c, !out.contains(where: { $0 === c }) { out.append(c) } }
        add(engine.car)
        for r in RaceSystem.shared?.session?.racers ?? [] { add(r.car) }
        for c in SplitScreen.current?.playerCars ?? [] { add(c) }
        return out
    }

    // MARK: Paso por fotograma

    private func step(frame: SceneFrame) {
        // dt del juego; si está quieto (pausa, menús del garaje, pruebas con dt 0) los garajes siguen animándose
        let now = CFAbsoluteTimeGetCurrent()
        let wall = Float(min(0.1, now - lastWall)); lastWall = now
        var dt = lastTime.map { max(0, min(0.1, frame.time - $0)) } ?? 0
        lastTime = frame.time
        if dt == 0, garageContext() != nil { dt = GarageSystem.fixedStep ?? wall }
        particles.interest = camerasThisFrame.isEmpty ? [(frame.camPos, viewForward(frame.view))] : camerasThisFrame
        camerasThisFrame = []

        // Emisores del garaje: se crean (calientes) al cambiar de garaje
        let ctx = garageContext()
        if ctx?.key != feKey || (ctx.map { $0.model != feModel } ?? false) {
            feGroups.forEach { particles.remove($0) }
            feGroups = []
            feKey = ctx?.key; feModel = ctx?.model ?? .identity
            if let ctx {
                for e in library.frontendEmitters[ctx.key] ?? [] {
                    guard let g = particles.makeGroup(e.group, flags: [.alwaysClose], matrix: ctx.model * e.matrix) else { continue }
                    g.autoUpdate = true
                    feGroups.append(g)
                    let life = g.emitters.map(\.def.life).max() ?? 0
                    particles.prewarm(g, seconds: min(life, 10))
                }
            }
        }
        if !inFrontEnd {
            particles.serviceWorld(triggerAt: physicsCars().map(\.position))
            if firstFrame { particles.prewarmWorld(seconds: 6) }
        }
        firstFrame = false
        if dt > 0 {
            carFX.update(cars: inFrontEnd ? [] : physicsCars(), dt: dt)
            particles.update(dt: dt)
            flares.tick(dt)
        }
    }

    private func viewForward(_ v: float4x4) -> float3 { -float3(v.columns.0.z, v.columns.1.z, v.columns.2.z) }

    // MARK: Luz de la vista (Renderer.encodeScene)

    /// Niebla por zona de la calle (no en los garajes del frontend). `view` = orden de la vista en el fotograma.
    func adjust(_ L: inout SceneLighting, frame: SceneFrame, view: Int) {
        guard !L.frontEnd || L.sky else { return }
        if let f = zone.fog(view: view, at: frame.camPos) {
            L.fog = f.params
            L.fogColor = f.colour
        }
    }
    /// Tinte de pantalla (RGB 0…255) de la vista principal.
    var screenTint: float3? { lastTint }
    private var lastTint: float3?

    // MARK: RenderOverlay

    func encodeOpaque(_ enc: MTLRenderCommandEncoder, frame: SceneFrame) {
        drawCalls = 0
        let r = engine.renderer
        camerasThisFrame.append((frame.camPos, viewForward(frame.view)))
        if r.frameIndex != lastFrame {
            lastFrame = r.frameIndex
            step(frame: frame)
            lastTint = inFrontEnd ? nil : zone.tint(view: 0, at: frame.camPos)
        }
    }

    func encodeTransparent(_ enc: MTLRenderCommandEncoder, frame: SceneFrame) {
        let viewProj = frame.proj * frame.view
        let frustum = Frustum(viewProj)
        // Partículas de la vista
        var blend: [(Float, ParticleInstance)] = [], add: [ParticleInstance] = []
        let cam = frame.camPos
        for g in particles.groups {
            for e in g.emitters where !e.particles.isEmpty {
                let d = e.def
                guard let slice = gpu.slice[d.texture] else { continue }
                let additive = (library.textureBlend[d.texture] ?? 1) == 2
                let n = d.animType
                for p in e.particles where p.size > 0.001 && p.colour.w > 0 {
                    if !frustum.intersects(AABB(min: p.pos - p.size * 1.5, max: p.pos + p.size * 1.5)) { continue }
                    var uv = float4(0, 0, 1, 1)
                    if n > 0 {   // GetAnimatedUVs [D]: rejilla N×N, fila = fotograma / N
                        let frames = n * n
                        let f = min(frames - 1, Int(p.animPhase * Float(frames - 1) + 0.5))
                        let w = 1 / Float(n)
                        uv = float4(Float(f % n) * w, Float(f / n) * w, Float(f % n + 1) * w, Float(f / n + 1) * w)
                    }
                    let inst = ParticleInstance(posSize: float4(p.pos, p.size), colour: p.colour / 128, uv: uv,
                                                misc: float4(Float(p.angle) * (2 * .pi / 65536), Float(slice), Float(d.axisConstraint), additive ? 1 : 0))
                    if additive { add.append(inst) } else { blend.append((simd_distance_squared(p.pos, cam), inst)) }
                }
            }
        }
        blend.sort { $0.0 > $1.0 }
        // Destellos de la vista
        var fl: [FlareInstance] = []
        let projY = frame.proj.columns.1.y
        if !inFrontEnd {
            flares.gatherWorld(&fl, frustum: frustum, cam: cam, projY: projY)
            gatherCarFlares(&fl, frame: frame, frustum: frustum, projY: projY)
            gatherSun(&fl, frame: frame, projY: projY)
        }
        lastParticles = blend.count + add.count; lastFlares = fl.count
        drawCalls += gpu.draw(enc, blend: blend.map(\.1), add: add, flares: fl, shafts: shafts.items(frame: frame))
    }

    func encodeScreen(_ cb: MTLCommandBuffer, target: MTLTexture) {}

    private func gatherCarFlares(_ fl: inout [FlareInstance], frame: SceneFrame, frustum: Frustum, projY: Float) {
        let t = frame.time
        for c in physicsCars() {
            let body = c.partMatrices[0]
            let p = float3(body.columns.3.x, body.columns.3.y, body.columns.3.z)
            guard simd_distance(p, frame.camPos) < 600, frustum.intersects(AABB(min: p - 4, max: p + 4)) else { continue }
            let braking = c.lastDriver.brake > 0.05 || c.lastDriver.handBrake > 0.5
            flares.gatherCar(&fl, model: c.modelName, body: body, traffic: false, braking: braking, reversing: c.gear == Gear.reverse,
                             copLights: false, time: t, cam: frame.camPos, projY: projY)
        }
        guard let ai = engine.ai else { return }
        for v in ai.vehicles + (engine.aiRenderer?.extraVehicles ?? []) {
            guard simd_distance(v.pos, frame.camPos) < 600, frustum.intersects(AABB(min: v.pos - 4, max: v.pos + 4)) else { continue }
            let body = v.partMatrices[0]
            flares.gatherCar(&fl, model: v.model.name, body: body, traffic: v.kind == .traffic, braking: v.braking, reversing: false,
                             copLights: v.lights, time: t + Float(v.id) * 0.7, cam: frame.camPos, projY: projY)
        }
    }

    /// Destello del sol (ELF_SUN_FLARE con `sun_flare` [V]; intensidad = GetSunIntensity [D], aquí 1 con el sol sobre el horizonte [I]).
    private func gatherSun(_ fl: inout [FlareInstance], frame: SceneFrame, projY: Float) {
        guard frame.lighting.useSun, let fx = engine.renderer.fx, fx.loaded else { return }
        let dir = simd_normalize(fx.sunPosition - frame.camPos)
        guard dir.z > 0 else { return }
        flares.add(&fl, type: 21, pos: frame.camPos + dir * 3000, dir: nil, intensity: min(1, dir.z * 10), cam: frame.camPos, projY: projY, sizeScale: 1)
    }
}
