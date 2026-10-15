// Escenas de garaje conducibles (garage-scenes/, tools/src/cli/garage-scenes.ts, docs/es/07 §5):
// lo que el juego no tiene porque allí la zona menu_gate_* carga el frontend [D]. Aquí:
//  - SHELL: paredes, techo, vigas, suelo y carteles del volumen interior del edificio con texturas del propio interior
//    del disco (tamaño de textura y luz horneada medidos en el interior): ya no se ve la calle a través del garaje.
//  - FRAME: jambas y dintel del hueco de la fachada.  APRON: umbral/rampa de la calle a la puerta (bordillos, desnivel).
//  - Colisión NFSC de la escena (muros del volumen y suelo del umbral) enganchada a CollisionWorld.
//  - El reflejo del interior del frontend (BACKDROP_REFLECTION, interiors/<NOMBRE>.reflection.glb) bajo el suelo
//    semitransparente del escenario del menú, como FEGeometryModels::Render [D].
//  - Cambio de coche sin pantallas de carga («Mis coches», concesionario): la cámara mira al techo, el coche nuevo
//    entra rodando desde la puerta con su física y se para en la plaza mientras la cámara vuelve.
import Foundation
import Metal
import simd

final class GarageScenes {
    struct Info: Decodable {
        struct Frame: Decodable { let door: [Float]; let out: [Float]; let yaw: Float }
        struct Volume: Decodable { let depth: Float; let width: Float; let height: Float; let left: Float; let right: Float; let source: String? }
        struct Shell: Decodable { let back: Float; let front: Float; let left: Float; let right: Float; let ceiling: Float; let gapHalfWidth: Float; let gapHeight: Float }
        struct Apron: Decodable { let area: [Float]; let street: Float? }
        let zone: String, kind: String, platform: String
        let frame: Frame, volume: Volume, shell: Shell
        let apron: Apron?
        let glb: String, collision: String
    }

    /// Una escena cargada (malla en el marco de la puerta + colisión en el mundo).
    final class Scene {
        let info: Info
        let model: float4x4
        let shell: GPUMesh?, apron: GPUMesh?
        /// Triángulos del umbral (9 floats) y muros del volumen (planta + alturas), en el mundo.
        let tris: [Float]
        let walls: [(a: SIMD2<Float>, b: SIMD2<Float>, zMin: Float, zMax: Float)]
        init(info: Info, model: float4x4, shell: GPUMesh?, apron: GPUMesh?, tris: [Float], walls: [(a: SIMD2<Float>, b: SIMD2<Float>, zMin: Float, zMax: Float)]) {
            self.info = info; self.model = model; self.shell = shell; self.apron = apron; self.tris = tris; self.walls = walls
        }
        var ground: Float { info.frame.door.count > 2 ? info.frame.door[2] : 0 }
        /// Suelo del umbral bajo (x, y) si cae dentro.
        func apronGround(_ x: Float, _ y: Float, _ z: Float) -> (z: Float, normal: float3)? {
            guard !tris.isEmpty, abs(z - ground) < 4 else { return nil }
            var best: (z: Float, normal: float3)? = nil
            var i = 0
            while i + 8 < tris.count {
                defer { i += 9 }
                let a = float3(tris[i], tris[i + 1], tris[i + 2]), b = float3(tris[i + 3], tris[i + 4], tris[i + 5]), c = float3(tris[i + 6], tris[i + 7], tris[i + 8])
                let v0 = SIMD2(b.x - a.x, b.y - a.y), v1 = SIMD2(c.x - a.x, c.y - a.y), v2 = SIMD2(x - a.x, y - a.y)
                let den = v0.x * v1.y - v1.x * v0.y
                if abs(den) < 1e-9 { continue }
                let u = (v2.x * v1.y - v1.x * v2.y) / den, v = (v0.x * v2.y - v2.x * v0.y) / den
                if u < -1e-4 || v < -1e-4 || u + v > 1 + 1e-4 { continue }
                let gz = a.z + u * (b.z - a.z) + v * (c.z - a.z)
                if gz > z + 1.2 { continue }
                if best == nil || gz > best!.z {
                    var n = simd_normalize(simd_cross(b - a, c - a)); if n.z < 0 { n = -n }
                    best = (gz, n)
                }
            }
            return best
        }
    }

    unowned let engine: Engine
    /// Depuración: ROCKPORT_SCENE_OFF=1 no dibuja la escena (para comparar con el interior solo).
    static let debugOff = ProcessInfo.processInfo.environment["ROCKPORT_SCENE_OFF"]
    /// Intensidad del reflejo del suelo del escenario (ROCKPORT_REFLECTION=0…1 para probar).
    static let reflectionTint: Float = ProcessInfo.processInfo.environment["ROCKPORT_REFLECTION"].flatMap(Float.init) ?? 0.5
    private let root: URL
    private var cache: [String: Scene?] = [:]
    private var reflections: [String: GPUMesh?] = [:]
    let available: Bool

    init(engine: Engine) {
        self.engine = engine
        root = engine.data.url("garage-scenes")
        available = FileManager.default.fileExists(atPath: root.appendingPathComponent("index.json").path)
        // Suelo del umbral antes que el del garaje (WorldGarages.floor), que solo cubre el interior y el pasillo
        let col = engine.collision
        let prev = col.groundOverride
        col.groundOverride = { [weak self] x, y, z in
            if let s = self?.activeScene, let g = s.apronGround(x, y, z) { return g }
            return prev?(x, y, z)
        }
    }

    /// Escena de una zona (zone_safehouse_1…), cargada la primera vez.
    func scene(_ zone: String) -> Scene? {
        if let s = cache[zone] { return s }
        var s: Scene? = nil
        defer { cache[zone] = s }
        guard available, let info = try? JSONDecoder().decode(Info.self, from: Data(contentsOf: root.appendingPathComponent("\(zone).json"))) else { return nil }
        let d = info.frame.door
        let model = float4x4(translation: float3(d[0], d[1], d.count > 2 ? d[2] : 0)) * float4x4(rotationZ: info.frame.yaw)
        var shell: GPUMesh? = nil, apron: GPUMesh? = nil
        let url = root.appendingPathComponent(info.glb)
        if let f = try? GLB.load(url) {
            let inside = f.primitives.filter { $0.nodeName != "APRON" }, outside = f.primitives.filter { $0.nodeName == "APRON" }
            if !inside.isEmpty { shell = GPUMesh.build(device: engine.device, file: f, textures: engine.textures, keyPrefix: url.path, prims: inside) }
            if !outside.isEmpty { apron = GPUMesh.build(device: engine.device, file: f, textures: engine.textures, keyPrefix: url.path + "#apron", prims: outside) }
        } else { fputs("escena de garaje: no se pudo leer \(url.path)\n", stderr) }
        var tris: [Float] = [], walls: [(a: SIMD2<Float>, b: SIMD2<Float>, zMin: Float, zMax: Float)] = []
        if let data = try? Data(contentsOf: root.appendingPathComponent(info.collision)), data.count >= 16 {
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self) == 0x4353464e else { return }
                let nt = Int(raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self)), nw = Int(raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
                guard raw.count >= 16 + (nt * 9 + nw * 6) * 4 else { return }
                tris = (0..<(nt * 9)).map { raw.loadUnaligned(fromByteOffset: 16 + $0 * 4, as: Float.self) }
                for k in 0..<nw {
                    let o = 16 + (nt * 9 + k * 6) * 4
                    let v = (0..<6).map { raw.loadUnaligned(fromByteOffset: o + $0 * 4, as: Float.self) }
                    walls.append((SIMD2(v[0], v[1]), SIMD2(v[2], v[3]), min(v[4], v[5]), max(v[4], v[5])))
                }
            }
        }
        s = Scene(info: info, model: model, shell: shell, apron: apron, tris: tris, walls: walls)
        return s
    }

    /// Volumen interior de la escena de una zona (marco de la puerta): fondo, paredes izquierda (+) y derecha (−), alto.
    func volume(_ zone: String) -> (depth: Float, left: Float, right: Float, height: Float)? {
        guard let v = scene(zone)?.info.volume else { return nil }
        return (v.depth, v.left, v.right, v.height)
    }

    /// Escena del garaje colocado ahora en el mundo (WorldGarages.current).
    var activeScene: Scene? {
        guard let g = engine.garages?.world?.current else { return nil }
        return scene(g.info.key)
    }

    /// Reflejo del interior del frontend (BACKDROP_REFLECTION), si el disco lo trae (solo el refugio).
    func reflection(_ interior: String) -> GPUMesh? {
        if let m = reflections[interior] { return m }
        let url = engine.data.url("interiors/\(interior).reflection.glb")
        var m: GPUMesh? = nil
        if FileManager.default.fileExists(atPath: url.path), let f = try? GLB.load(url) {
            m = GPUMesh.build(device: engine.device, file: f, textures: engine.textures, keyPrefix: url.path)
        }
        reflections[interior] = m
        return m
    }

    // MARK: Dibujo

    /// Piezas que añade la escena a lo que dibuja la capa de garajes este fotograma.
    func drawItems(stage: FEStage, world: WorldGarages?) -> [GarageDrawItem] {
        var out: [GarageDrawItem] = []
        if stage.active {
            if let r = reflection(stage.kind.interior) {
                let model = float4x4(translation: FEStage.origin + float3(0, stage.kind.geometryY, 0)) * float4x4(rotationZ: stage.kind.geometryZAngle * .pi / 180)
                // Atenuado: el suelo deja ver el reflejo por su alfa, y la copia invertida no lleva la luz del techo [I]
                out.append(GarageDrawItem(mesh: r, model: model, clip: nil, tint: float3(repeating: GarageScenes.reflectionTint)))
            }
            return out
        }
        guard let w = world, let g = w.current, let s = scene(g.info.key), GarageScenes.debugOff == nil else { return out }
        // El umbral está en la calle: se ve siempre que el garaje esté colocado (a menos de 150 m)
        if let a = s.apron { out.append(GarageDrawItem(mesh: a, model: s.model, clip: nil)) }
        // El volumen interior solo con la fachada recortada (puerta abierta o dentro)
        if GarageCutout.active, let sh = s.shell { out.append(GarageDrawItem(mesh: sh, model: s.model, clip: nil, tint: GarageMods.color(g.mod.tint))) }
        return out
    }

    // MARK: Paso por fotograma

    private var placedKey: String?
    private var appended = 0
    private var appendedLast: (a: SIMD2<Float>, b: SIMD2<Float>, zMin: Float, zMax: Float)?
    /// Tras WorldGarages.update: muros de la escena con la fachada recortada, y el cambio de coche.
    func update(camDt: Float) {
        if let w = engine.garages?.world, let g = w.current {
            if placedKey != g.info.key {
                placedKey = g.info.key
                _ = scene(g.info.key)
            }
            // WorldGarages.update rehace garageWalls en cada paso de conducción, pero no con el coche en otro modo: se quitan
            // los de la escena que quedaran del fotograma anterior antes de volver a ponerlos
            var walls = engine.collision.garageWalls
            if appended > 0, walls.count >= appended, let last = walls.last, let mine = appendedLast, last.a == mine.a, last.b == mine.b { walls.removeLast(appended) }
            appended = 0; appendedLast = nil
            if GarageCutout.active, let s = scene(g.info.key), !s.walls.isEmpty { walls += s.walls; appended = s.walls.count; appendedLast = s.walls.last }
            engine.collision.garageWalls = walls
        } else { placedKey = nil; appended = 0; appendedLast = nil }
        swap?.update(dt: camDt)
    }

    // MARK: Cambio de coche (concesionario y «Mis coches»)

    private var swap: CarSwap?
    /// Coche que se enseña en la plaza (nil = el del jugador). Con animación si ya había uno a la vista.
    func preview(key: String?) {
        guard let w = engine.garages?.world else { return }
        guard let key, let player = engine.car, let g = w.current else {
            swap?.finish(); swap = nil
            w.preview(key: nil)
            return
        }
        if swap?.key == key { return }
        // El coche que ya lleva el jugador no hace falta traerlo
        let playerKey = Career.shared.active ? Career.shared.save.currentCar : (Config.playerPreset ?? Config.playerCar)
        if key == playerKey && swap == nil { w.preview(key: nil); return }
        guard let car = CarTuning.build(key, engine: engine) else { return }
        w.preview(key: nil)
        let s = CarSwap(key: key, car: car, previous: swap?.car, spot: player.position, yaw: player.yaw, ground: g.ground, maxRun: max(2.5, min(5.5, simd_length(SIMD2(player.position.x - g.doorP.x, player.position.y - g.doorP.y)) - 1.2)), mover: w.mover)
        swap = s
    }
    /// En el fotograma: el coche de la animación ocupa el sitio del coche aparcado.
    func apply(_ f: inout SceneFrame) {
        guard let s = swap, !(engine.garages?.stage.active ?? false), GarageCutout.active else { return }
        // Mientras la cámara se va sigue a la vista el coche de antes (el del jugador, que ya dibuja el motor, o el anterior)
        if s.showNew { f.car = (s.car.mesh, s.car.partMatrices); f.carShadow = s.car.shadowMatrix }
        else if let o = s.previous { f.car = (o.mesh, o.partMatrices); f.carShadow = o.shadowMatrix }
    }
    var swapping: Bool { swap.map { !$0.done } ?? false }
    var swapDebug: String { swap.map { $0.debug } ?? "—" }
}

/// Cambio de coche sin cortes: la cámara del frontend mira al techo (0,45 s), el coche nuevo aparece a unos metros detrás
/// de la plaza (hacia la puerta, fuera de cuadro) y entra rodando con su física hasta la plaza mientras la cámara vuelve.
final class CarSwap {
    let key: String
    let car: Car
    private let spot: float3, yaw: Float
    private let ground: FlatGround
    private let run: Float
    private weak var mover: FECameraMover?
    private var back: FECameraAngle?
    private var t: Float = 0
    private var phase = 0          // 0 la cámara se va · 1 el coche entra · 2 parado
    private(set) var done = false

    /// Coche que había a la vista (nil = el del jugador).
    let previous: Car?
    var showNew: Bool { phase >= 1 }
    init(key: String, car: Car, previous: Car?, spot: float3, yaw: Float, ground: Float, maxRun: Float, mover: FECameraMover) {
        self.key = key; self.car = car; self.previous = previous; self.spot = spot; self.yaw = yaw; self.ground = FlatGround(z: ground); run = maxRun; self.mover = mover
        back = mover.current
        var away = mover.current
        // Mirar arriba (vigas y luces del techo): el punto de mira sube y el coche sale de cuadro por abajo. Solo cambia la
        // altura del punto de mira, así la comprobación de muros de la cámara del garaje (en planta) no se altera.
        away.lookAt += float3(0, 0, 2.8)
        away.animSpeed = 0.45
        mover.setDesired(away)
        // El coche espera detrás de la plaza, mirando hacia ella
        let fwd = float3(cos(yaw), sin(yaw), 0)
        car.place(spot - fwd * run + float3(0, 0, 0.5), yaw: yaw, ground: self.ground, probe: 2)
        for _ in 0..<20 { car.update(dt: 1.0 / 60, input: Car.Input(handbrake: true), collision: self.ground) }
    }

    func update(dt: Float) {
        guard !done else { return }
        t += dt
        switch phase {
        case 0:
            car.update(dt: dt, input: Car.Input(handbrake: true), collision: ground)
            if t > 0.4 { phase = 1; t = 0; if let b = back { var r = b; r.animSpeed = 1.1; mover?.setDesired(r) } }
        case 1:
            // Velocidad deseada según lo que falta (frenada suave) y control de gas/freno
            let fwd = float3(cos(yaw), sin(yaw), 0)
            let left = simd_dot(spot - car.position, fwd)
            let want = max(0, min(3.2, sqrt(max(0, 2 * 1.6 * (left - 0.05)))))
            var inp = Car.Input()
            if left < 0.08 || t > 4 { inp.brake = 1; inp.handbrake = car.kmh < 1 }
            else if car.speed < want - 0.2 { inp.throttle = min(0.6, 0.25 + (want - car.speed) * 0.3) }
            else if car.speed > want + 0.15 { inp.brake = min(1, (car.speed - want) * 0.8) }
            car.update(dt: dt, input: inp, collision: ground)
            if (left < 0.1 && car.kmh < 0.5) || t > 5 { phase = 2; t = 0 }
        default:
            car.update(dt: dt, input: Car.Input(handbrake: true), collision: ground)
            if t > 0.6 { done = true }
        }
    }
    var debug: String {
        let fwd = float3(cos(yaw), sin(yaw), 0)
        return String(format: "fase %d · falta %.2f m · %.1f km/h · lateral %.2f", phase, simd_dot(spot - car.position, fwd), car.kmh, simd_dot(spot - car.position, float3(-fwd.y, fwd.x, 0)))
    }
    /// Cerrar al momento (salir del menú a mitad de animación): la cámara vuelve a su ángulo.
    func finish() { if !done, let b = back { mover?.setDesired(b) }; done = true }
}
