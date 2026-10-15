// Garajes sin pantallas de carga en el mundo, como el visor (viewer/src/garage.ts + main.ts), con la lógica del juego:
// en el original la zona menu_gate_* llama a EQuitToFE(GARAGETYPE_*) y sale del mundo [D]; aquí el interior del menú
// (FRONTEND\PLATFORMS\*.BIN) se coloca de verdad dentro del edificio y se entra conduciendo.
//
//  1. A menos de 150 m de una zona (garages.json, tools/src/cli/garages.ts) se coloca su interior detrás de la puerta real
//     (triángulos con ARC_HOSPITAL_GARAGEDOOR [V]) orientado por su lado abierto (rayos), recortado al volumen del edificio.
//  2. Al llegar despacio frente a la puerta (como al entrar en la zona del juego), el edificio se recorta (hueco de la puerta
//     + volumen interior, shaders del mundo) y la persiana nueva sube con la textura original.
//  3. Dentro: colisión del interior; al pararse en la plaza la persiana baja y salen los menús del juego de ese sitio
//     (GarageMenus.swift) con la cámara del frontend (angle_final_<garaje>) alrededor del coche.
//  4. «Volver a la zona libre»: la persiana sube, se sale marcha atrás y al alejarse se cierra y todo vuelve a su estado.
// Sin edificio identificado (refugios 2, 4 y 5) la puerta mira hacia el punto de reaparición [H] y el interior queda dentro
// de una caja de 16 × 10 × 5 m con su propio muro trasero (GarageMenus muestra el mismo refugio) [I].
import Foundation
import Metal
import simd

struct GarageInfo: Decodable {
    struct Building: Decodable { let name: String; let center: [Float]; let along: Float; let across: Float; let height: Float; let floor: Float }
    let collection: String
    let zoneType: String
    let zone: [Float]
    let radius: Float
    let building: Building?
    let out: [Float]
    let door: [Float]
    let doorSize: [Float]?
    let doorTexture: String?
    let source: String
    var key: String { collection.split(separator: "/").last.map(String.init) ?? collection }
}

/// Mods de garajes (mods/*/mod.json, «garages»): nombre, interior, tinte y coches de exposición.
struct GarageMod: Decodable {
    struct Display: Decodable { let car: String; let paint: String?; let offset: [Float]; let yaw: Float? }
    var name: String?
    var interior: String?
    var tint: String?
    var display: [Display]?
}

enum GarageMods {
    private struct File: Decodable { let id: String; let garages: [String: GarageMod]? }
    /// Todos los mods con garajes (el último gana, orden alfabético como el visor).
    static func load(_ data: GameData) -> [String: GarageMod] {
        var dirs: [URL] = []
        let root = data.root.standardizedFileURL
        dirs.append(root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("mods"))   // repo: map-data/<ID>/../../mods
        dirs.append(DataLocator.appSupport.appendingPathComponent("mods"))
        if let env = ProcessInfo.processInfo.environment["ROCKPORT_MODS"] { dirs.insert(URL(fileURLWithPath: env), at: 0) }
        var out: [String: GarageMod] = [:]
        for d in dirs {
            guard let subs = try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil) else { continue }
            for s in subs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let f = try? JSONDecoder().decode(File.self, from: Data(contentsOf: s.appendingPathComponent("mod.json"))) else { continue }
                for (k, g) in f.garages ?? [:] {
                    var m = out[k] ?? GarageMod()
                    if let v = g.name { m.name = v }
                    if let v = g.interior { m.interior = v }
                    if let v = g.tint { m.tint = v }
                    if let v = g.display { m.display = v }
                    out[k] = m
                }
            }
            if !out.isEmpty { break }
        }
        return out
    }
    static func color(_ hex: String?) -> float3 {
        guard let h = hex?.replacingOccurrences(of: "#", with: ""), let v = UInt32(h, radix: 16) else { return float3(1, 1, 1) }
        return float3(Float((v >> 16) & 255), Float((v >> 8) & 255), Float(v & 255)) / 255
    }
}

/// Persiana enrollable: listones con la textura original de la puerta; cada listón enseña su franja de la imagen.
final class RollerDoor {
    let slats: [GPUMesh]
    let width: Float, height: Float
    var open: Float = 0, target: Float = 0
    private let slatH: Float

    init?(device: MTLDevice, textures: TextureCache, texture: URL?, width: Float, height: Float) {
        self.width = width; self.height = height
        let n = max(6, Int((height / 0.3).rounded()))
        slatH = height / Float(n)
        let tex = texture.flatMap { textures.texture(url: $0) }
        var list: [GPUMesh] = []
        let g = half(0.78), up = packNormal(float3(1, 0, 0))
        for i in 0..<n {
            // Plano vertical (Y = ancho, Z = alto) mirando a +X (fuera); V de la imagen de arriba (0) a abajo (1)
            let v0 = 1 - Float(i) / Float(n), v1 = 1 - Float(i + 1) / Float(n)
            let h = slatH * 0.96
            var vs = [Vertex(px: 0, py: -width / 2, pz: 0, u: 0, v: v0, r: g, g: g, b: g, a: half(1), normal: up),
                      Vertex(px: 0, py: width / 2, pz: 0, u: 1, v: v0, r: g, g: g, b: g, a: half(1), normal: up),
                      Vertex(px: 0, py: width / 2, pz: h, u: 1, v: v1, r: g, g: g, b: g, a: half(1), normal: up),
                      Vertex(px: 0, py: -width / 2, pz: h, u: 0, v: v1, r: g, g: g, b: g, a: half(1), normal: up)]
            var idx: [UInt32] = [0, 1, 2, 0, 2, 3]
            guard let vb = device.makeBuffer(bytes: &vs, length: MemoryLayout<Vertex>.stride * 4, options: .storageModeShared),
                  let ib = device.makeBuffer(bytes: &idx, length: 24, options: .storageModeShared) else { return nil }
            var b = AABB.empty; for v in vs { b.add(float3(v.px, v.py, v.pz)) }
            list.append(GPUMesh(vertexBuffer: vb, indexBuffer: ib, draws: [DrawRange(kind: .opaque, indexStart: 0, indexCount: 6, texture: tex,
                                                                                     color: float4(1, 1, 1, 1), cutoff: 0, role: nil, name: "persiana", wrap: 0)],
                                bounds: b, triangles: 2))
        }
        slats = list
    }

    func update(dt: Float) {
        let d = target - open
        open += (d > 0 ? 1 : -1) * min(abs(d), dt / 1.4)
    }
    /// Matrices de los listones (espacio de la puerta: X fuera, Y a lo ancho, Z arriba) con la persiana subida `open`.
    func slatModels(_ base: float4x4) -> [(GPUMesh, float4x4)] {
        let e = open < 0.5 ? 4 * open * open * open : 1 - pow(-2 * open + 2, 3) / 2    // aceleración suave
        let lift = e * height
        var out: [(GPUMesh, float4x4)] = []
        for (i, s) in slats.enumerated() {
            let z = Float(i) * slatH + lift
            if z >= height - 0.02 { continue }
            out.append((s, base * float4x4(translation: float3(0.05, 0, z))))
        }
        return out
    }
}

final class WorldGarages {
    enum Phase: String { case closed, opening, inside, parked, menu, leaving }

    /// Un garaje colocado en el mundo.
    final class Placed {
        let info: GarageInfo
        let kind: GarageKind
        let interior: String
        let mod: GarageMod
        let interiorModel: float4x4
        let clip: float4x4          // mundo → caja del interior
        let inner: float4x4         // caja → mundo: volumen interior del edificio (recorte)
        let corridor: float4x4      // caja → mundo: hueco de la puerta (recorte)
        let doorP: float3
        let out: float3, left: float3
        let yawOut: Float
        let ground: Float
        let doorW: Float, doorH: Float
        let spot: float3
        let depth: Float, width: Float, height: Float
        var walls: [(a: SIMD2<Float>, b: SIMD2<Float>, zMin: Float, zMax: Float)] = []
        var display: [Car] = []
        let door: RollerDoor?
        init(info: GarageInfo, kind: GarageKind, interior: String, mod: GarageMod, interiorModel: float4x4, clip: float4x4, inner: float4x4,
             corridor: float4x4, doorP: float3, out: float3, yawOut: Float, ground: Float, doorW: Float, doorH: Float, spot: float3,
             depth: Float, width: Float, height: Float, door: RollerDoor?) {
            self.info = info; self.kind = kind; self.interior = interior; self.mod = mod; self.interiorModel = interiorModel; self.clip = clip
            self.inner = inner; self.corridor = corridor; self.doorP = doorP; self.out = out; left = float3(-out.y, out.x, 0)
            self.yawOut = yawOut; self.ground = ground; self.doorW = doorW; self.doorH = doorH; self.spot = spot
            self.depth = depth; self.width = width; self.height = height; self.door = door
        }
        /// Distancia con signo al plano de la puerta (+ fuera, − dentro).
        func pastDoor(_ p: float3) -> Float { simd_dot(p - doorP, out) }
        var name: String { mod.name ?? "" }
    }

    unowned let engine: Engine
    let library: InteriorLibrary
    let infos: [GarageInfo]
    let mods: [String: GarageMod]
    private(set) var current: Placed?
    private(set) var phase: Phase = .closed
    private var parkedTime: Float = 0
    private var phaseTime: Float = 0
    /// Cámara del frontend alrededor del coche aparcado (se usa en .parked/.menu).
    let mover = FECameraMover(FECameraAngle.fallback)
    var onParked: ((Placed) -> Void)?
    /// Log de las pruebas (--garage-test).
    var log: ((String) -> Void)?
    private var displayGround: FlatGround?
    /// La zona solo abre la puerta si el jugador ha estado fuera de ella antes (ver .closed).
    private var armed = false
    /// Corrección de la cámara del frontend dentro del garaje (giro extra y escala del radio).
    private var camFix: (dh: Float, k: Float) = (0, 1)

    init?(engine: Engine, library: InteriorLibrary) {
        guard let d = try? Data(contentsOf: engine.data.url("garages.json")),
              let f = try? JSONDecoder().decode([String: [GarageInfo]].self, from: d.filteredGarages()), let list = f["garages"] else { return nil }
        self.engine = engine; self.library = library; infos = list
        mods = GarageMods.load(engine.data)
        let col = engine.collision
        col.ignoreWall = { [weak self] a, b, z0, z1 in self?.ignores(a, b, z0, z1) ?? false }
        col.groundOverride = { [weak self] x, y, z in self?.floor(x, y, z) }
    }

    // MARK: Colocación (viewer/src/main.ts placeGarageNow)

    func place(_ info: GarageInfo) -> Placed? {
        let mod = mods[info.key] ?? GarageMod()
        let kind = GarageKind.forZone(info.zoneType)
        let interiorName = mod.interior ?? kind.interior
        guard library.worldMesh(interiorName) != nil else { return nil }
        var out = float3(info.out.count >= 2 ? info.out[0] : 1, info.out.count >= 2 ? info.out[1] : 0, 0)
        out = simd_length(out) > 0 ? simd_normalize(out) : float3(1, 0, 0)
        let yawOut = atan2(out.y, out.x)
        let ground = info.door.count >= 3 ? info.door[2] : info.zone[2]
        let doorP = float3(info.door[0], info.door[1], ground)
        let doorW = info.doorSize.map { $0[0] } ?? 6, doorH = info.doorSize.map { $0[1] } ?? 4
        // Volumen interior del edificio: de la puerta hacia dentro hasta su cara trasera; sin edificio, 16 × 10 × 5 m
        let b = info.building
        let behind: Float = b.map { simd_dot(float3($0.center[0] - doorP.x, $0.center[1] - doorP.y, 0), -out) + $0.along / 2 } ?? 16
        var depth = max(8, min(behind, 40)), width = b.map { min($0.across, 30) } ?? 10, height = b.map { max(4, min($0.height, 9)) } ?? 5
        let rotOut = float4x4(rotationZ: yawOut)
        let leftDir = float3(-out.y, out.x, 0)
        func box(_ c: float3, _ half: float3) -> float4x4 { float4x4(translation: c) * rotOut * float4x4(scale: half) }
        // Volumen de la escena conducible (garage-scenes/, medido con la colisión del mundo): nave real detrás de la puerta,
        // con sus paredes a izquierda y derecha (puede no estar centrada en la puerta). El recorte va 8 cm por dentro de las
        // paredes de la escena para que no se coma fachadas a los lados (GarageScenes.swift).
        let vol = GarageSystem.shared?.scenes.volume(info.key)
        var innerCenter = doorP - out * (depth / 2)
        var inner = box(float3(innerCenter.x, innerCenter.y, ground + 0.15 + (height - 0.95) / 2), float3(depth / 2 - 0.6, width / 2 - 0.8, (height - 0.95) / 2))
        var clipBox = box(float3(innerCenter.x, innerCenter.y, ground - 0.6 + (height + 0.6) / 2), float3(depth / 2 - 0.4, width / 2 - 0.5, (height + 0.6) / 2))
        if let v = vol {
            depth = v.depth; width = v.left - v.right; height = v.height
            let mid = (v.left + v.right) / 2
            let x0: Float = -depth + 0.08, x1: Float = -0.6
            innerCenter = doorP + out * ((x0 + x1) / 2) + leftDir * mid
            inner = box(float3(innerCenter.x, innerCenter.y, ground + 0.15 + (height - 0.95) / 2), float3((x1 - x0) / 2, width / 2 - 0.08, (height - 0.95) / 2))
            let c0: Float = -depth + 0.05, c1: Float = -0.3
            let cc = doorP + out * ((c0 + c1) / 2) + leftDir * mid
            clipBox = box(float3(cc.x, cc.y, ground - 0.6 + (height + 0.6) / 2), float3((c1 - c0) / 2, width / 2 - 0.06, (height + 0.6) / 2))
        }
        // Hueco de la puerta: empieza 12 cm sobre la calle. Antes bajaba 10 cm por debajo y se comía el suelo de la calle
        // ±2,5 m alrededor de la persiana, donde el interior (recortado a su caja) no llega: por el agujero se veía el mar
        // (banda gris en la parte de abajo de la pantalla al entrar). Doc 20 §5.
        let corridor = box(float3(doorP.x, doorP.y, ground + 0.12 + doorH / 2), float3(2.5, doorW / 2 + 0.15, doorH / 2))
        // Interior: lado abierto hacia la puerta, plaza (su origen) dentro, suelo a la altura de la calle
        let tris = library.triangles(interiorName)
        let lay = WorldGarages.analyze(tris)
        let rot = yawOut - atan2(lay.openDir.y, lay.openDir.x)
        let spotDist = min(max(depth * 0.5, 7), lay.depth, depth - 3)
        let origin = float3(doorP.x, doorP.y, ground - lay.floorZ) - out * spotDist
        let model = float4x4(translation: origin) * float4x4(rotationZ: rot)
        let clip = clipBox.inverse
        // Plaza alcanzable: hasta la pared del fondo del interior (dentro del edificio), con margen
        var reach = spotDist + 3
        do {
            let o = doorP + float3(0, 0, 1) - out * 1.5, dir = -out
            let inv = model.inverse
            let lo = inv * float4(o, 1), ld = inv * float4(dir, 0)
            var best = Float.greatestFiniteMagnitude
            var i = 0
            while i + 2 < tris.count {
                if let t = WorldGarages.ray(float3(lo.x, lo.y, lo.z), float3(ld.x, ld.y, ld.z), tris[i], tris[i + 1], tris[i + 2]), t < best {
                    let hp = o + dir * t, l = clip * float4(hp, 1)
                    if abs(l.x) <= 1 && abs(l.y) <= 1 { best = t }
                }
                i += 3
            }
            if best < 60 { reach = best + 1.5 }
        }
        let d = max(5.5, min(spotDist, reach - 3.2))
        let spot = float3(doorP.x, doorP.y, ground) - out * d
        let texURL = info.doorTexture.map { engine.data.url("textures/\($0).png") }
        let door = RollerDoor(device: engine.device, textures: engine.textures, texture: texURL, width: doorW, height: doorH)
        let p = Placed(info: info, kind: kind, interior: interiorName, mod: mod, interiorModel: model, clip: clip, inner: inner, corridor: corridor,
                       doorP: doorP, out: out, yawOut: yawOut, ground: ground, doorW: doorW, doorH: doorH, spot: spot,
                       depth: depth, width: width, height: height, door: door)
        p.walls = WorldGarages.walls(tris, model: model, clip: clip, ground: ground) + facade(p)
        // Coches de exposición del mod (x = hacia la puerta, y = izquierda, respecto a la plaza)
        let g = FlatGround(z: ground)
        displayGround = g
        for dsp in mod.display ?? [] {
            guard let c = Car(device: engine.device, data: engine.data, textures: engine.textures, name: dsp.car, paint: GarageMods.color(dsp.paint)) else { continue }
            let pos = spot + out * (dsp.offset.count > 0 ? dsp.offset[0] : 0) + p.left * (dsp.offset.count > 1 ? dsp.offset[1] : 0)
            c.place(pos + float3(0, 0, 0.5), yaw: yawOut + (dsp.yaw ?? 0) * .pi / 180, ground: g, probe: 2)
            for _ in 0..<30 { c.update(dt: 1.0 / 60, input: Car.Input(handbrake: true), collision: g) }
            p.display.append(c)
        }
        log?(String(format: "garaje %@ (%@): interior %@ · %@ · fondo %.1f m, ancho %.1f, alto %.1f · plaza a %.1f m · %d muros · suelo %.2f, abierto (%.2f, %.2f) a %.1f m",
                    info.key, info.source, interiorName, b?.name ?? "sin edificio", depth, width, height, d, p.walls.count, lay.floorZ, lay.openDir.x, lay.openDir.y, lay.depth))
        return p
    }

    /// Muros de la fachada a los lados del hueco de la puerta (el muro original de la fachada se ignora entero si cruza el hueco).
    private func facade(_ p: Placed) -> [(a: SIMD2<Float>, b: SIMD2<Float>, zMin: Float, zMax: Float)] {
        let half = p.width / 2 + 1.5, gap = p.doorW / 2 + 0.25
        func xy(_ v: float3) -> SIMD2<Float> { SIMD2(v.x, v.y) }
        let l0 = p.doorP + p.left * gap, l1 = p.doorP + p.left * half
        let r0 = p.doorP - p.left * gap, r1 = p.doorP - p.left * half
        return [(xy(l0), xy(l1), p.ground - 1, p.ground + p.height), (xy(r0), xy(r1), p.ground - 1, p.ground + p.height)]
    }

    /// Altura del suelo bajo el origen del interior y su lado abierto (16 rayos a 1,2 m) [viewer: analyzeInterior].
    static func analyze(_ tris: [float3]) -> (floorZ: Float, openDir: SIMD2<Float>, depth: Float) {
        func cast(_ o: float3, _ d: float3) -> Float? {
            var best: Float? = nil
            var i = 0
            while i + 2 < tris.count {
                if let t = ray(o, d, tris[i], tris[i + 1], tris[i + 2]), t < (best ?? .greatestFiniteMagnitude) { best = t }
                i += 3
            }
            return best
        }
        let floorZ = cast(float3(0, 0, 4), float3(0, 0, -1)).map { 4 - $0 } ?? 0
        var bestD: Float = -1, dir = SIMD2<Float>(1, 0)
        for i in 0..<16 {
            let a = Float(i) / 16 * 2 * .pi
            let d = float3(cos(a), sin(a), 0)
            // Pasillo del ancho de un coche (±1 m) a dos alturas: pretiles bajos (concesionario), elevadores con un coche
            // encima y columnas del taller no dejan pasar aunque el rayo central a 1,2 m esté libre
            let side = float3(-d.y, d.x, 0)
            var t: Float = 200
            for off: Float in [-1, 0, 1] { for h: Float in [0.45, 1.2] { t = min(t, cast(side * off + float3(0, 0, floorZ + h), d) ?? 200) } }
            if t > bestD { bestD = t; dir = SIMD2(d.x, d.y) }
        }
        var bb = AABB.empty; for v in tris { bb.add(v) }
        let ex = dir.x > 0 ? bb.max.x : bb.min.x, ey = dir.y > 0 ? bb.max.y : bb.min.y
        let depth = min(abs(ex / (abs(dir.x) > 1e-4 ? dir.x : 1e-4)), abs(ey / (abs(dir.y) > 1e-4 ? dir.y : 1e-4)))
        return (floorZ, dir, min(depth, 25))
    }

    /// Möller–Trumbore (doble cara).
    static func ray(_ o: float3, _ d: float3, _ a: float3, _ b: float3, _ c: float3) -> Float? {
        let e1 = b - a, e2 = c - a, p = simd_cross(d, e2)
        let det = simd_dot(e1, p)
        if abs(det) < 1e-8 { return nil }
        let inv = 1 / det, s = o - a
        let u = simd_dot(s, p) * inv
        if u < 0 || u > 1 { return nil }
        let q = simd_cross(s, e1), v = simd_dot(d, q) * inv
        if v < 0 || u + v > 1 { return nil }
        let t = simd_dot(e2, q) * inv
        return t > 1e-4 ? t : nil
    }

    /// Muros del interior: triángulos casi verticales dentro de la caja del edificio y a la altura del coche.
    static func walls(_ tris: [float3], model: float4x4, clip: float4x4, ground: Float) -> [(a: SIMD2<Float>, b: SIMD2<Float>, zMin: Float, zMax: Float)] {
        var out: [(a: SIMD2<Float>, b: SIMD2<Float>, zMin: Float, zMax: Float)] = []
        var seen = Set<SIMD4<Int32>>()
        var i = 0
        while i + 2 < tris.count {
            defer { i += 3 }
            let w = [tris[i], tris[i + 1], tris[i + 2]].map { v -> float3 in let r = model * float4(v, 1); return float3(r.x, r.y, r.z) }
            let n = simd_cross(w[1] - w[0], w[2] - w[0])
            let ln = simd_length(n)
            if ln < 1e-5 || abs(n.z / ln) > 0.35 { continue }
            let z0 = w.map(\.z).min()!, z1 = w.map(\.z).max()!
            if z1 < ground + 0.3 || z0 > ground + 1.6 || z1 - z0 < 0.25 { continue }
            var a = w[0], b = w[1], best: Float = 0
            for (p, q) in [(w[0], w[1]), (w[1], w[2]), (w[0], w[2])] {
                let l = simd_length(SIMD2(p.x - q.x, p.y - q.y))
                if l > best { best = l; a = p; b = q }
            }
            if best < 0.3 { continue }
            let m = (a + b) * 0.5, lc = clip * float4(m.x, m.y, ground + 1, 1)
            if abs(lc.x) > 1 || abs(lc.y) > 1 { continue }
            let key = SIMD4<Int32>(Int32(a.x * 4), Int32(a.y * 4), Int32(b.x * 4), Int32(b.y * 4))
            if !seen.insert(key).inserted { continue }
            out.append((SIMD2(a.x, a.y), SIMD2(b.x, b.y), z0, z1))
        }
        return out
    }

    // MARK: Colisión

    /// Muro del edificio que se ignora con el garaje abierto: cruza el hueco de la puerta o cae dentro del volumen interior.
    private func ignores(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ z0: Float, _ z1: Float) -> Bool {
        guard GarageCutout.active, let g = current else { return false }
        let z = max(z0, min(z1, g.ground + 1))
        let m = (a + b) * 0.5
        if GarageCutout.contains(float3(m.x, m.y, z)) { return true }
        // ¿Cruza el segmento el rectángulo del hueco? (en el espacio de la caja del pasillo)
        let inv = g.corridor.inverse
        let la = inv * float4(a.x, a.y, z, 1), lb = inv * float4(b.x, b.y, z, 1)
        return WorldGarages.segmentHitsUnitSquare(SIMD2(la.x, la.y), SIMD2(lb.x, lb.y))
    }
    static func segmentHitsUnitSquare(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Bool {
        var t0: Float = 0, t1: Float = 1
        let d = b - a
        for k in 0..<2 {
            if abs(d[k]) < 1e-6 { if a[k] < -1 || a[k] > 1 { return false }; continue }
            var ta = (-1 - a[k]) / d[k], tb = (1 - a[k]) / d[k]
            if ta > tb { swap(&ta, &tb) }
            t0 = max(t0, ta); t1 = min(t1, tb)
            if t0 > t1 { return false }
        }
        return true
    }

    /// Suelo del interior (plano a la altura de la calle) mientras el garaje está abierto.
    private func floor(_ x: Float, _ y: Float, _ z: Float) -> (z: Float, normal: float3)? {
        guard GarageCutout.active, let g = current else { return nil }
        let p = float3(x, y, g.ground + 0.5)
        guard abs(z - g.ground) < 3 else { return nil }
        let l = g.inner.inverse * float4(p, 1), c = g.corridor.inverse * float4(p, 1)
        if (abs(l.x) < 1.15 && abs(l.y) < 1.15) || (abs(c.x) < 1 && abs(c.y) < 1) { return (g.ground, float3(0, 0, 1)) }
        return nil
    }

    private func setCutout(_ on: Bool) {
        guard let g = current else { GarageCutout.uniforms.on = .zero; return }
        GarageCutout.uniforms = CutoutUniforms(a: g.corridor.inverse, b: g.inner.inverse, on: float4(on ? 1 : 0, 0, 0, 0))
        updateWalls()
    }
    private func updateWalls() {
        guard let g = current, GarageCutout.active else { engine.collision.garageWalls = []; return }
        var w = g.walls
        // Persiana cerrada (o a medias): muro en el hueco
        if (g.door?.open ?? 1) < 0.9 {
            let a = g.doorP + g.left * (g.doorW / 2 + 0.2), b = g.doorP - g.left * (g.doorW / 2 + 0.2)
            w.append((SIMD2(a.x, a.y), SIMD2(b.x, b.y), g.ground - 1, g.ground + g.doorH))
        }
        engine.collision.garageWalls = w
    }

    // MARK: Fotograma

    var playerPos: float3? { engine.car?.position }

    func update(dt: Float, camDt: Float) {
        guard let car = engine.car, engine.mode == .drive || phase == .menu || phase == .parked else { return }
        let p = car.position
        // Precarga del garaje más cercano (a menos de 150 m) mientras el actual esté cerrado
        if phase == .closed {
            let near = infos.map { ($0, simd_distance(SIMD2(p.x, p.y), SIMD2($0.door[0], $0.door[1]))) }.min { $0.1 < $1.1 }
            if let (info, dist) = near, dist < 150, current?.info.collection != info.collection { current = place(info); armed = false }
            else if let c = current, simd_distance(SIMD2(p.x, p.y), SIMD2(c.doorP.x, c.doorP.y)) > 220 { current = nil }
        }
        guard let g = current else { return }
        g.door?.update(dt: dt > 0 ? dt : camDt)
        phaseTime += dt
        let past = g.pastDoor(p)
        let lateral = abs(simd_dot(p - g.doorP, g.left))
        let kmh = car.kmh
        switch phase {
        case .closed:
            // Como la zona menu_gate del juego: llegar despacio delante de la puerta, viniendo de fuera (al salir del
            // garaje o al reaparecer en el refugio no se vuelve a abrir hasta alejarse) [I]
            let zoneD = simd_distance(SIMD2(p.x, p.y), SIMD2(g.info.zone[0], g.info.zone[1]))
            let inTrigger = (zoneD < g.info.radius + 8 || (past > 0 && past < 14 && lateral < g.doorW))
            if !inTrigger && (zoneD > g.info.radius + 14 || past > 18) { armed = true }
            // Dentro de la propia zona del juego (radio + 2 m) basta con estar; cerca de la puerta, hay que acercarse
            let approaching = simd_dot(car.velocity, -g.out) > 1 || past < 6 || zoneD < g.info.radius + 2
            if ProcessInfo.processInfo.environment["ROCKPORT_GARAGE_DEBUG"] != nil, Int(phaseTime * 60) % 60 == 0 {
                log?(String(format: "  cerrado: zona %.1f m · puerta %.1f m · lateral %.1f · %.0f km/h · armado %@ · acercándose %@", zoneD, past, lateral, kmh, armed ? "sí" : "no", approaching ? "sí" : "no"))
            }
            if armed && inTrigger && approaching && kmh < 45 {
                setPhase(.opening); setCutout(true); g.door?.target = 1
            }
        case .opening:
            if past < -3 { setPhase(.inside) }
            else if past > 30 || lateral > 30 { setPhase(.leaving); g.door?.target = 0 }
        case .inside:
            let d = simd_distance(SIMD2(p.x, p.y), SIMD2(g.spot.x, g.spot.y))
            parkedTime = d < 4 && kmh < 2 ? parkedTime + dt : 0
            if parkedTime > 0.5 { park(g, car: car) }
            else if past > 3 { setPhase(.leaving) }
        case .parked, .menu:
            break
        case .leaving:
            if past > 4, (g.door?.open ?? 1) >= 1 { g.door?.target = 0 }
            if past > 2, (g.door?.open ?? 0) <= 0.001 { setCutout(false); setPhase(.closed); armed = false }
            if past < -3 { setPhase(.inside); g.door?.target = 1 }
        }
        updateWalls()
        if phase == .parked || phase == .menu { mover.update(dt: camDt) }
    }

    private func setPhase(_ p: Phase) {
        if p != phase { log?("garaje \(current?.info.key ?? "—"): \(phase.rawValue) → \(p.rawValue)") }
        phase = p; phaseTime = 0
    }

    /// Aparcado: la persiana baja y la cámara pasa sin cortes de la de persecución a la del frontend del garaje.
    private func park(_ g: Placed, car: Car) {
        setPhase(.parked)
        camFix = (0, 1)
        g.door?.target = 0
        mover.setCurrent(angleFromChase(car))
        let final = FECameraAngle.table["angle_final_\(g.kind.rawValue)"] ?? FECameraAngle.fallback
        var f = final; f.animSpeed = max(1.6, min(final.animSpeed, 3))
        mover.setDesired(f)
        onParked?(g)
    }

    /// Ángulo del frontend equivalente a la cámara de persecución actual (para la transición).
    private func angleFromChase(_ car: Car) -> FECameraAngle {
        let r = carFrame(car).inverse
        let e = r * float4(engine.chasePos - car.position, 0), t = r * float4(engine.chaseTarget - car.position, 0)
        let rel = float3(e.x, e.y, e.z), radius = max(0.5, simd_length(rel))
        let v = acos(max(-1, min(1, -rel.z / radius))) * 180 / .pi
        let h = atan2(-rel.x, -rel.y) * 180 / .pi
        return FECameraAngle(orbitV: v, orbitH: h, radius: radius, roll: 0, fov: 70, lookAt: float3(t.x, t.y, t.z), animSpeed: 1, damping: 8, periods: 1)
    }
    /// Del espacio del frontend (coche girado CarRotationZ) al mundo, alrededor del coche aparcado.
    private func carFrame(_ car: Car) -> float4x4 {
        let k = current?.kind ?? .safehouse
        return float4x4(rotationZ: car.yaw - k.carRotationZ * .pi / 180)
    }

    /// Salida del garaje («Volver a la zona libre»): la persiana sube y el jugador conduce hacia fuera.
    func exitGarage() {
        guard let g = current else { return }
        g.door?.target = 1
        setPhase(.leaving)
    }
    func menuOpened() { setPhase(.menu) }

    /// Concesionario / «Mis coches»: el coche que se mira ocupa el sitio del aparcado (nil = el del jugador otra vez).
    private(set) var previewCar: Car?
    private var previewKey: String?
    func preview(key: String?) {
        guard let key, let car = engine.car, let g = current else { previewCar = nil; previewKey = nil; return }
        guard key != previewKey else { return }
        previewKey = key
        guard let c = CarTuning.build(key, engine: engine) else { previewCar = nil; return }
        let ground = FlatGround(z: g.ground)
        c.place(float3(car.position.x, car.position.y, g.ground + 0.5), yaw: car.yaw, ground: ground, probe: 2)
        for _ in 0..<30 { c.update(dt: 1.0 / 60, input: Car.Input(handbrake: true), collision: ground) }
        previewCar = c
    }
    /// El jugador sigue dentro tras cerrar los menús sin salir (p. ej. cambio de coche): vuelve a .inside.
    func resumeInside() { setPhase(.inside); parkedTime = -1.5 }

    /// Pantalla del menú: su cam_angle (FE_ATTRIB.BIN).
    func screenAngle(_ name: String) { mover.setDesired(FECameraAngle.forScreen(name)) }

    func apply(_ f: inout SceneFrame, aspect: Float) {
        guard let g = current, GarageCutout.active else { return }
        for c in g.display { f.extraCars.append((c.mesh, c.partMatrices, c.shadowMatrix)) }
        if let pc = previewCar { f.car = (pc.mesh, pc.partMatrices); f.carShadow = pc.shadowMatrix }
        if (phase == .parked || phase == .menu), let car = engine.car {
            // Cámara del frontend alrededor del coche, en el sistema del coche (FE: coche en el origen, girado CarRotationZ)
            let toWorld = float4x4(translation: car.position) * carFrame(car)
            // La cámara no atraviesa los coches de exposición ni los muros del interior: se busca el giro horizontal más
            // cercano al del juego con la vista libre y, si no hay, se acerca [I]. Se recuerda para no saltar cada fotograma.
            let target4 = toWorld * float4(mover.current.lookAt, 1), target = SIMD2(target4.x, target4.y)
            func blocked(_ dh: Float, _ k: Float) -> Bool {
                var a = mover.current; a.orbitH += dh; a.radius *= k
                let e4 = toWorld * float4(a.eye, 1), e = SIMD2(e4.x, e4.y)
                for c in g.display where c !== car {
                    let p = SIMD2(c.position.x, c.position.y), ab = e - target, l2 = simd_length_squared(ab)
                    let u = l2 > 0 ? max(0, min(1, simd_dot(p - target, ab) / l2)) : 0
                    if simd_distance(target + ab * u, p) < 2.4 { return true }
                }
                for w in g.walls where RaceBarrierLines.intersect(w.a, w.b, target, e) { return true }
                return false
            }
            if blocked(camFix.dh, camFix.k) {
                var found: (Float, Float)? = nil
                outer: for k: Float in [1, 0.85, 0.7, 0.55] {
                    for step in 0...9 {
                        for sgn: Float in [1, -1] where !(step == 0 && sgn < 0) {
                            let dh = Float(step) * 20 * sgn
                            if !blocked(dh, k) { found = (dh, k); break outer }
                        }
                    }
                }
                camFix = found ?? (0, 0.45)
            }
            mover.userH = camFix.dh
            let scale = camFix.k
            let m = mover.matrices(origin: .zero, aspect: aspect, radiusScale: scale)
            let view = m.view * toWorld.inverse
            let eye4 = toWorld * float4(m.eye, 1)
            f.view = view; f.proj = m.proj; f.camPos = float3(eye4.x, eye4.y, eye4.z)
        }
    }

    var drawItems: [GarageDrawItem] {
        guard let g = current, GarageCutout.active, let m = library.worldMesh(g.interior) else { return [] }
        let noClip = ProcessInfo.processInfo.environment["ROCKPORT_GARAGE_NOCLIP"] != nil
        var items = [GarageDrawItem(mesh: m, model: g.interiorModel, clip: noClip ? nil : g.clip, tint: GarageMods.color(g.mod.tint))]
        if let door = g.door {
            let base = float4x4(translation: g.doorP) * float4x4(rotationZ: g.yawOut)
            for (s, model) in door.slatModels(base) { items.append(GarageDrawItem(mesh: s, model: model, clip: nil)) }
        }
        return items
    }

    // MARK: Pruebas

    /// Coloca el garaje de la zona y deja el coche del jugador delante de la puerta (o dentro, en la plaza).
    func debugPlace(zone key: String, insideAt: Bool) -> Placed? {
        guard let info = infos.first(where: { $0.key == key || $0.collection == key }), let car = engine.car else { return nil }
        current = place(info)
        guard let g = current else { return nil }
        if insideAt {
            setCutout(true); g.door?.open = 1; g.door?.target = 1
            car.place(g.spot + float3(0, 0, 1), yaw: g.yawOut + .pi, collision: engine.collision, probe: 3)
            setPhase(.inside)
        } else {
            car.place(g.doorP + g.out * 18 + float3(0, 0, 2), yaw: g.yawOut + .pi, collision: engine.collision)
            armed = true
        }
        return g
    }
    var debugPhase: Phase { phase }
}

private extension Data {
    /// garages.json ya es {disc, garages:[…]}: se queda solo con «garages».
    func filteredGarages() -> Data {
        guard let o = try? JSONSerialization.jsonObject(with: self) as? [String: Any], let g = o["garages"] else { return self }
        return (try? JSONSerialization.data(withJSONObject: ["garages": g])) ?? self
    }
}
