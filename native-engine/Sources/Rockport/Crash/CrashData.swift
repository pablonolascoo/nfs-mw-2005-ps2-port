// Datos de los choques del juego, leídos de map-data/<ID>/ (formato 11):
//   bounds.json      CollisionGeometry::Bounds de 83 coches y 405 objetos del mundo [D: Physics/Bounds.h][V] (doc 22 §5)
//   physics.json     rigidbodyspecs (OBJ_FRICTION, OBJ_ELASTICITY, OBJ_MOMENT_SCALE…) y damagespecs de cada pvehicle,
//                    y todas las colecciones rigidbodyspecs (los rompibles usan "smackable", "watertower"…) [V]
//   effects.json     smackableTypes (VLT smackable: MASS, DETACH_FORCE, MOMENT, COST_TO_STATE…) y smokeables (5 952
//                    rompibles: tipo, colisión, posición) [V] (doc 24 §3); positionMarkers (*Moment = derrumbes) [V]
//   smackables.json  la instancia de escenario de cada rompible (modelo y matriz) que ya no va en la casilla [V]
// Todo en metros. Las cajas de los coches están en el espacio del modelo del juego: x derecha, y arriba, z adelante.
import Foundation
import simd

/// Un volumen de colisión (caja o esfera) en el espacio del modelo del juego.
struct CrashPrimDef {
    var center: V3
    var rot: simd_quatf
    var half: V3
    var sphere: Bool
    var radius: Float
    var surface: String?
}

/// Lo que la respuesta de choques necesita de un rigidbodyspecs [D: RigidBody.cpp ResolveObjectCollision, ModifyCollision].
struct CrashRBSpecs {
    var objFriction = SIMD2<Float>(0.55, 0.35)        // [estática, dinámica]
    var objElasticity = V3(0, 0, 0.05)                // por eje del cuerpo
    var objMomentScale = SIMD4<Float>(1, 1, 1, 0)     // xyz escala de inercia, w escala de masa (> 0)
    var immobileObjectCollisions = false
    var wallFriction = SIMD2<Float>(0.2, 0.1)
    var wallElasticity = V3(0, 0, 0.15)
    var groundFriction = SIMD2<Float>(0.55, 0.45)
    var gravity: Float = -9.8128
    var sleepVelocity: Float = 1
    var drag = V3(0, 0, 0)
    var dragAngular = V3(0, 0, 0)

    init() {}
    init(_ d: [String: Any]) {
        func v(_ k: String) -> [Float] { (d[k] as? [NSNumber])?.map(\.floatValue) ?? [] }
        let f = v("OBJ_FRICTION"); if f.count >= 2 { objFriction = SIMD2(f[0], f[1]) }
        let e = v("OBJ_ELASTICITY"); if e.count >= 3 { objElasticity = V3(e[0], e[1], e[2]) }
        let m = v("OBJ_MOMENT_SCALE"); if m.count >= 4 { objMomentScale = SIMD4(m[0], m[1], m[2], m[3]) }
        immobileObjectCollisions = d["IMMOBILE_OBJECT_COLLISIONS"] as? Bool ?? false
        let wf = v("WALL_FRICTION"); if wf.count >= 2 { wallFriction = SIMD2(wf[0], wf[1]) }
        let we = v("WALL_ELASTICITY"); if we.count >= 3 { wallElasticity = V3(we[0], we[1], we[2]) }
        let gf = v("GROUND_FRICTION"); if gf.count >= 2 { groundFriction = SIMD2(gf[0], gf[1]) }
        if let g = d["GRAVITY"] as? NSNumber { gravity = g.floatValue }
        if let s = d["SLEEP_VELOCITY"] as? NSNumber { sleepVelocity = s.floatValue }
        let dr = v("DRAG"); if dr.count >= 3 { drag = V3(dr[0], dr[1], dr[2]) }
        let da = v("DRAG_ANGULAR"); if da.count >= 3 { dragAngular = V3(da[0], da[1], da[2]) }
    }
}

/// damagespecs [D: DamageVehicle.cpp OnImpact]: FORCE × 1000 = resistencia del material; por zona VisualScale / HitPointScale.
struct DamageSpecs {
    var force: Float = 20
    var hitPoints: Float = 0
    var hpThreshold: Float = 0
    var shockTime: Float = 3
    var shockForce: Float = 40
    var suppressDist: Float = 0
    var visual = [Float](repeating: 0, count: DamageZone.count)
    var hitPoint = [Float](repeating: 0, count: DamageZone.count)

    init() {}
    init(_ d: [String: Any]) {
        force = (d["FORCE"] as? NSNumber)?.floatValue ?? 20
        hitPoints = (d["HIT_POINTS"] as? NSNumber)?.floatValue ?? 0
        hpThreshold = (d["HP_THRESHOLD"] as? NSNumber)?.floatValue ?? 0
        shockTime = (d["SHOCK_TIME"] as? NSNumber)?.floatValue ?? 3
        shockForce = (d["SHOCK_FORCE"] as? NSNumber)?.floatValue ?? 40
        suppressDist = (d["SUPPRESS_DIST"] as? NSNumber)?.floatValue ?? 0
        for z in DamageZone.allCases {
            guard let r = d[z.attribute] as? [String: Any] else { continue }
            visual[z.rawValue] = (r["VisualScale"] as? NSNumber)?.floatValue ?? 0
            hitPoint[z.rawValue] = (r["HitPointScale"] as? NSNumber)?.floatValue ?? 0
        }
    }
}

/// Física de choque de un pvehicle.
struct VehicleCrashSpecs {
    var name: String
    var model: String
    var mass: Float
    var tensorScale: V3
    var rb: CrashRBSpecs
    var damage: DamageSpecs?
    var isCop: Bool
}

/// Tipo de rompible (clase VLT `smackable`) [V: effects.json library.smackableTypes].
struct SmackableType {
    var name: String
    var mass: Float = 100
    var detachForce: Float = 0
    var moment = V3(1.5, 1.5, 1.5)
    var costToState = 0
    var killOffScreen: Float = 8
    var respawnTime: Float = 120
    var noCarEffect = true
    var simple = false
    var rigidbody = "smackable"
    var eventSequencer = ""
}

/// Un rompible del mundo.
struct SmackableDef {
    var id: Int
    var type: String
    var collision: String
    var model: String
    var glb: String?
    var matrix: float4x4
    var pos: float3
}

final class CrashData {
    private(set) var carBounds: [String: (root: V3, prims: [CrashPrimDef])] = [:]
    private(set) var worldBounds: [String: (root: V3, prims: [CrashPrimDef])] = [:]
    private(set) var vehicles: [String: VehicleCrashSpecs] = [:]      // por pvehicle (minúsculas) y por modelo (MAYÚSCULAS)
    private(set) var rigidbodies: [String: CrashRBSpecs] = [:]
    private(set) var smackTypes: [String: SmackableType] = [:]
    private(set) var smackables: [SmackableDef] = []
    private(set) var moments: [(name: String, pos: float3)] = []
    /// Hay rompibles separados de las casillas (formato 11): solo entonces se pueden tirar sin dejar el original pintado.
    private(set) var smackablesSeparate = false
    private(set) var report: [String] = []

    private static var cache: (String, CrashData)?
    static func shared(_ data: GameData) -> CrashData {
        if let c = cache, c.0 == data.root.path { return c.1 }
        let d = CrashData(root: data.root)
        cache = (data.root.path, d)
        return d
    }

    private static func json(_ u: URL) -> [String: Any]? {
        guard let d = try? Data(contentsOf: u) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    private static func prims(_ list: [[String: Any]]) -> (V3, [CrashPrimDef]) {
        var root = V3(1, 0.7, 2.3)
        var out: [CrashPrimDef] = []
        for (i, b) in list.enumerated() {
            let names = b["flagNames"] as? [String] ?? []
            func f3(_ k: String) -> V3 { let a = (b[k] as? [NSNumber])?.map(\.floatValue) ?? [0, 0, 0]; return V3(a[0], a[1], a[2]) }
            let half = f3("halfDimensions")
            if i == 0 { root = half }
            // Solo los volúmenes contra objetos [D: OnObjectOverlap: flag 2 (PrimVsObjects), no Disabled (8)]; los
            // «Internal» son de piezas que se sueltan (puertas, parachoques) [I]: no cuentan para el cuerpo.
            guard names.contains("PrimVsObjects"), !names.contains("Disabled"), !names.contains("Internal") else { continue }
            let q = (b["orientation"] as? [NSNumber])?.map(\.floatValue) ?? [0, 0, 0, 1]
            let sphere = names.contains("Sphere")
            out.append(CrashPrimDef(center: f3("position"), rot: simd_quatf(ix: q[0], iy: q[1], iz: q[2], r: q[3]), half: half,
                                    sphere: sphere, radius: (b["radius"] as? NSNumber)?.floatValue ?? simd_reduce_max(half),
                                    surface: b["surface"] as? String))
        }
        // Objetos del mundo sin volumen PrimVsObjects (solo PrimVsWorld): se usa la caja raíz entera [I]
        if out.isEmpty, let b = list.first {
            let q = (b["orientation"] as? [NSNumber])?.map(\.floatValue) ?? [0, 0, 0, 1]
            let p = (b["position"] as? [NSNumber])?.map(\.floatValue) ?? [0, 0, 0]
            out.append(CrashPrimDef(center: V3(p[0], p[1], p[2]), rot: simd_quatf(ix: q[0], iy: q[1], iz: q[2], r: q[3]), half: root, sphere: false,
                                    radius: simd_length(root), surface: nil))
        }
        return (root, out)
    }

    init(root: URL) {
        // Volúmenes
        if let b = CrashData.json(root.appendingPathComponent("bounds.json")) {
            for c in b["cars"] as? [[String: Any]] ?? [] {
                guard let n = c["name"] as? String, let list = c["bounds"] as? [[String: Any]] else { continue }
                carBounds[n.uppercased()] = CrashData.prims(list)
            }
            for c in b["world"] as? [[String: Any]] ?? [] {
                guard let list = c["bounds"] as? [[String: Any]] else { continue }
                let p = CrashData.prims(list)
                if let n = c["name"] as? String { worldBounds[n] = p }
                if let h = c["nameHash"] as? String { worldBounds[h] = p }
            }
        } else { report.append("falta bounds.json") }
        // Física
        if let p = CrashData.json(root.appendingPathComponent("physics.json")) {
            for (n, any) in p["rigidbodyspecs"] as? [String: Any] ?? [:] { if let d = any as? [String: Any] { rigidbodies[n] = CrashRBSpecs(d) } }
            for (n, any) in p["vehicles"] as? [String: Any] ?? [:] {
                guard let v = any as? [String: Any] else { continue }
                let ts = (v["tensorScale"] as? [NSNumber])?.map(\.floatValue) ?? [1, 1, 1]
                let rb = (v["rigidbody"] as? [String: Any]).map(CrashRBSpecs.init) ?? CrashRBSpecs()
                let dmg = (v["damage"] as? [String: Any]).map(DamageSpecs.init)
                let model = (v["model"] as? String ?? n).uppercased()
                let beh = v["behaviors"] as? [String: Any]
                let s = VehicleCrashSpecs(name: n, model: model, mass: (v["mass"] as? NSNumber)?.floatValue ?? 1500,
                                          tensorScale: V3(ts.count > 0 ? max(ts[0], 0.1) : 1, ts.count > 1 ? max(ts[1], 0.1) : 1, ts.count > 2 ? max(ts[2], 0.1) : 1),
                                          rb: rb, damage: dmg, isCop: (beh?["damage"] as? String) == "DamageCopCar")
                vehicles[n.lowercased()] = s
                if vehicles[model] == nil || n.lowercased() == model.lowercased() { vehicles[model] = s }
            }
            if p["rigidbodyspecs"] == nil { report.append("physics.json sin rigidbodyspecs (formato < 11): rompibles con valores por defecto") }
        }
        // Rompibles
        if let e = CrashData.json(root.appendingPathComponent("effects.json")) {
            let lib = (e["library"] as? [String: Any])?["smackableTypes"] as? [String: Any] ?? [:]
            for (n, any) in lib {
                guard let d = any as? [String: Any] else { continue }
                var t = SmackableType(name: n)
                t.mass = (d["MASS"] as? NSNumber)?.floatValue ?? 100
                t.detachForce = (d["DETACH_FORCE"] as? NSNumber)?.floatValue ?? 0
                if let m = (d["MOMENT"] as? [NSNumber])?.map(\.floatValue), m.count >= 3 { t.moment = V3(m[0], m[1], m[2]) }
                t.costToState = (d["COST_TO_STATE"] as? NSNumber)?.intValue ?? 0
                t.killOffScreen = (d["KILL_OFF_SCREEN"] as? NSNumber)?.floatValue ?? 8
                t.respawnTime = (d["RESPAWN_TIME"] as? NSNumber)?.floatValue ?? 120
                t.noCarEffect = d["NO_CAR_EFFECT"] as? Bool ?? true
                t.simple = d["SimplePhysics"] as? Bool ?? false
                t.rigidbody = ((d["rigidbodyspecs"] as? [String: Any])?["collection"] as? String) ?? "smackable"
                t.eventSequencer = d["EventSequencer"] as? String ?? ""
                smackTypes[n] = t
            }
            var placed: [Int: (glb: String, m: float4x4)] = [:]
            if let s = CrashData.json(root.appendingPathComponent("smackables.json")) {
                smackablesSeparate = true
                for o in s["objects"] as? [[String: Any]] ?? [] {
                    guard let id = (o["id"] as? NSNumber)?.intValue, let g = o["glb"] as? String, let m = (o["matrix"] as? [NSNumber])?.map(\.floatValue), m.count == 16 else { continue }
                    placed[id] = (g, float4x4(columns: (SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]), SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15]))))
                }
            }
            for o in e["smokeables"] as? [[String: Any]] ?? [] {
                guard let id = (o["id"] as? NSNumber)?.intValue, let p = (o["pos"] as? [NSNumber])?.map(\.floatValue), p.count == 3 else { continue }
                let pos = float3(p[0], p[1], p[2])
                let pl = placed[id]
                let yaw = ((o["yaw"] as? NSNumber)?.floatValue ?? 0) * .pi / 180
                smackables.append(SmackableDef(id: id, type: o["type"] as? String ?? "default", collision: o["collision"] as? String ?? "",
                                               model: o["sceneryModel"] as? String ?? o["model"] as? String ?? "", glb: pl?.glb,
                                               matrix: pl?.m ?? (float4x4(translation: pos) * float4x4(rotationZ: yaw)), pos: pos))
            }
            for m in e["positionMarkers"] as? [[String: Any]] ?? [] {
                guard let n = m["name"] as? String, n.hasSuffix("Moment"), n != "BustedMomentMarker",
                      let p = (m["pos"] as? [NSNumber])?.map(\.floatValue), p.count == 3 else { continue }
                moments.append((n, float3(p[0], p[1], p[2])))
            }
        } else { report.append("falta effects.json: sin rompibles") }
        if !smackablesSeparate { report.append("sin smackables.json (datos < 11): los rompibles siguen en las casillas y no se mueven") }
    }

    /// Volúmenes de un coche por modelo (COPMIDSIZE…); si falta, una caja de las medidas dadas.
    func carPrims(model: String, fallbackHalf: V3) -> (root: V3, prims: [CrashPrimDef]) {
        if let b = carBounds[model.uppercased()], !b.prims.isEmpty { return b }
        return (fallbackHalf, [CrashPrimDef(center: .zero, rot: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), half: fallbackHalf, sphere: false, radius: simd_length(fallbackHalf), surface: "carbody")])
    }

    func vehicle(_ name: String) -> VehicleCrashSpecs? { vehicles[name.lowercased()] ?? vehicles[name.uppercased()] }
}
