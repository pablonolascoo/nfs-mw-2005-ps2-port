// Objetos rompibles del mundo («smackables»: señales, farolas, semáforos, vallas, conos, bidones, bancos, cabinas…).
// 5 952 en Rockport [V: effects.json smokeables], con su colisión del juego (bounds.json, mCollisionName) y su tipo VLT
// `smackable` (MASS, DETACH_FORCE, MOMENT, COST_TO_STATE, KILL_OFF_SCREEN, RESPAWN_TIME) [V].
//
// Comportamiento:
//  · Al empezar están quietos y «pegados al mundo» (RigidBody::AttachedToWorld(true, DETACH_FORCE)) [D]. En el choque se
//    tratan como inmóviles con fuerza de rotura DETACH_FORCE: si el impulso la supera se sueltan (Detach) y desde ahí son
//    un cuerpo rígido libre [D: ResolveObjectCollision, ModifyCollision]. DETACH_FORCE 0 = suelto desde el principio
//    (conos, bancos); −1 = no se rompe con golpes (estructuras de los derrumbes) [I: Moment::React no decompilado].
//  · Cuerpo libre: gravedad del rigidbodyspecs (smackable: −13 m/s²), arrastre DRAG/DRAG_ANGULAR como RigidBody::DoDrag [D],
//    suelo de la colisión real con GROUND_FRICTION (esquinas de la caja como DoInstanceCollision2d) [D, simplificado],
//    reposo por SLEEP_VELOCITY [D: ShouldSleep] e inercia = caja × MOMENT [I].
//  · Desaparece fuera de pantalla tras KILL_OFF_SCREEN s y vuelve a su sitio tras RESPAWN_TIME s sin que se vea [I: nombres].
// El modelo se dibuja aparte (Crash/SmackableRender.swift) porque ya no está en las casillas (formato 11).
import Foundation
import simd

final class Smackable {
    enum State { case attached, loose, moving, sleeping, gone }
    let def: SmackableDef
    let type: SmackableType
    let rb: CrashRBSpecs
    let root: V3                         // medias medidas de la caja raíz (espacio de simulación: x, y arriba, z)
    let localPrims: [CrashPrimDef]       // espacio de simulación del objeto
    let localCG: float3                  // centro de la caja raíz en el mundo-local (Z arriba) [I]
    var state: State
    // Pose (mundo, Z arriba): origen y giro del objeto
    var pos: float3
    var q: simd_quatf
    let pos0: float3, q0: simd_quatf
    var vel = float3(0, 0, 0), ang = float3(0, 0, 0)
    var offscreen: Float = 0
    var goneTime: Float = 0
    var contacts = 0
    var lastHitTime: Float = -100
    var hitByPlayer = false
    var breakerGroup: Int?
    var listed = false                   // en SmackableField.active

    var mass: Float { type.mass }
    let inertia: V3                      // diagonal en ejes locales (mundo-local)

    init(def: SmackableDef, type: SmackableType, rb: CrashRBSpecs, bounds: (root: V3, prims: [CrashPrimDef])?) {
        self.def = def; self.type = type; self.rb = rb
        pos = def.pos; pos0 = def.pos
        // Giro del objeto en el mundo: el de su instancia de escenario (columnas 0–2 de la matriz, sin escala)
        let m = def.matrix
        var c0 = float3(m.columns.0.x, m.columns.0.y, m.columns.0.z), c1 = float3(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        c0 = simd_normalize(c0 + 1e-9); c1 = simd_normalize(c1 - c0 * simd_dot(c0, c1) + 1e-9)
        let c2 = simd_cross(c0, c1)
        q = simd_quatf(float3x3(c0, c1, c2)); q0 = q
        let b = bounds ?? (V3(0.3, 1, 0.3), [CrashPrimDef(center: V3(0, 1, 0), rot: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), half: V3(0.3, 1, 0.3), sphere: false, radius: 1, surface: nil)])
        root = b.root
        localPrims = b.prims
        // Centro de la caja raíz: media de los centros de sus volúmenes [I]
        let avg = b.prims.reduce(V3(0, 0, 0)) { $0 + $1.center } / Float(max(1, b.prims.count))
        localCG = PM.toWorld(avg)
        let w = 2 * root.x, h = 2 * root.y, l = 2 * root.z
        let box = V3((h * h + l * l) / 12, (w * w + l * l) / 12, (w * w + h * h) / 12) * type.mass
        inertia = simd_abs(PM.toWorld(box * type.moment))
        state = type.detachForce == 0 ? .loose : .attached
    }

    var isStatic: Bool { state == .attached || state == .loose || state == .sleeping }
    var immobileForCars: Bool { state == .attached }
    var R: float3x3 { float3x3(q) }
    var cg: float3 { pos + q.act(localCG) }

    /// Volúmenes en el mundo. Los del disco están en el espacio de simulación: se pasan con toWorld y el giro del objeto.
    /// (Su giro de simulación ya coincide con el de la instancia [V: 5 952/5 952 a menos de 5 cm].)
    func prims() -> [CrashPrim] {
        let Rm = R
        return localPrims.map { d in
            let c = pos + q.act(PM.toWorld(d.center))
            let a0 = Rm * PM.toWorld(d.rot.act(V3(1, 0, 0))), a1 = Rm * PM.toWorld(d.rot.act(V3(0, 1, 0))), a2 = Rm * PM.toWorld(d.rot.act(V3(0, 0, 1)))
            // ejes del mundo: x_sim → −Y, y_sim → Z, z_sim → X; las medias medidas van con su eje
            return CrashPrim(c: c, ax: float3x3(a0, a1, a2), e: d.half, sphere: d.sphere, r: d.sphere ? d.radius : simd_length(d.half), surface: d.surface)
        }
    }
    var boundRadius: Float { simd_length(root) + 0.5 }

    /// Matriz para dibujar: la de la instancia movida con el cuerpo.
    var renderMatrix: float4x4 {
        if state == .attached || state == .loose { return def.matrix }
        let d = q * q0.inverse
        return float4x4(translation: pos) * float4x4(d) * float4x4(translation: -pos0) * def.matrix
    }

    func invI(_ x: float3, scale: V3 = V3(1, 1, 1)) -> float3 {
        let Rm = R
        let l = Rm.transpose * x
        return Rm * (l / simd_max(inertia * simd_abs(PM.toWorld(scale)), V3(repeating: 1e-3)))
    }

    func detach(now: Float) {
        guard state == .attached || state == .loose || state == .sleeping else { return }
        state = .moving
        lastHitTime = now
    }

    func respawn() {
        pos = pos0; q = q0; vel = .zero; ang = .zero
        state = type.detachForce == 0 ? .loose : .attached
        offscreen = 0; goneTime = 0; hitByPlayer = false
    }

    /// Un paso del cuerpo libre (gravedad, arrastre, suelo, reposo).
    func step(dt: Float, ground: CollisionWorld) {
        guard state == .moving else { return }
        // Gravedad [D: OnBeginFrame] y arrastre [D: DoDrag]: F = −½·ρ·|v|·v·A·C con A = 4·dim² por eje local
        var force = float3(0, 0, rb.gravity * mass)
        let Rm = R
        let dimW = simd_abs(PM.toWorld(root))
        let vl = Rm.transpose * vel
        let area = dimW * dimW * 4
        let C = simd_abs(PM.toWorld(rb.drag))
        force += Rm * (-0.5 * 1.225 * simd_length(vel) * vl * area * C)
        let al = Rm.transpose * ang
        let cs = float3(dimW.x * 4 * sqrt(dimW.y * dimW.y + dimW.z * dimW.z), dimW.y * 4 * sqrt(dimW.x * dimW.x + dimW.z * dimW.z), dimW.z * 4 * sqrt(dimW.x * dimW.x + dimW.y * dimW.y))
        let torque = Rm * (-0.5 * 1.225 * simd_length(ang) * al * cs * simd_abs(PM.toWorld(rb.dragAngular)))
        vel += force / mass * dt
        ang += invI(torque * dt)
        ang = simd_clamp(ang, float3(repeating: -20), float3(repeating: 20))
        pos += vel * dt
        let w = simd_length(ang)
        if w > 1e-5 {
            let c0 = cg
            q = simd_normalize(simd_quatf(angle: w * dt, axis: ang / w) * q)
            pos += c0 - cg       // giro alrededor del CG
        }
        // Suelo: esquinas de la caja raíz [D: DoInstanceCollision2d, versión propia del impulso]
        contacts = 0
        let rootW = simd_abs(PM.toWorld(root))
        let center = cg
        var deepest: (pen: Float, p: float3, n: float3)? = nil
        for sx in [-1, 1] as [Float] { for sy in [-1, 1] as [Float] { for sz in [-1, 1] as [Float] {
            let p = center + Rm * (rootW * float3(sx, sy, sz))
            guard let g = ground.ground(x: p.x, y: p.y, z: p.z, step: 1.0) else { continue }
            let pen = g.z - p.z
            if pen > 0 {
                contacts += 1
                if deepest == nil || pen > deepest!.pen { deepest = (pen, p, g.normal) }
            }
        } } }
        if let d = deepest {
            pos.z += d.pen
            let r = d.p - cg
            let v = vel + simd_cross(ang, r)
            let vn = simd_dot(v, d.n)
            if vn < 0 {
                let k = 1 / mass + simd_dot(d.n, simd_cross(invI(simd_cross(r, d.n)), r))
                let jn = -vn / k
                var J = d.n * jn
                let vt = v - d.n * vn, vtl = simd_length(vt)
                if vtl > 1e-4 {
                    let t = vt / vtl
                    let kt = 1 / mass + simd_dot(t, simd_cross(invI(simd_cross(r, t)), r))
                    J -= t * min(vtl / kt, rb.groundFriction.x * jn)
                }
                vel += J / mass
                ang += invI(simd_cross(r, J))
            }
        }
        // Reposo [D: ShouldSleep: |v| + |ω|·radio < SLEEP_VELOCITY con más de 2 puntos de contacto]
        if simd_length(vel) + simd_length(ang) * simd_length(root) < rb.sleepVelocity && contacts > 2 {
            state = .sleeping; vel = .zero; ang = .zero
        }
        if pos.z < pos0.z - 60 { state = .gone }   // cayó fuera del mapa
    }
}

/// Todos los rompibles, con una rejilla de 16 m para buscar los cercanos.
final class SmackableField {
    private(set) var all: [Smackable] = []
    private var grid: [SIMD2<Int32>: [Int]] = [:]
    static let cell: Float = 16
    var active: [Smackable] = []         // en movimiento (se simulan cada paso)
    let enabled: Bool

    init(data: CrashData) {
        enabled = data.smackablesSeparate
        for d in data.smackables {
            let t = data.smackTypes[d.type] ?? SmackableType(name: d.type)
            let rb = data.rigidbodies[t.rigidbody] ?? data.rigidbodies["smackable"] ?? CrashRBSpecs()
            let s = Smackable(def: d, type: t, rb: rb, bounds: data.worldBounds[d.collision])
            all.append(s)
            grid[key(d.pos), default: []].append(all.count - 1)
        }
    }

    private func key(_ p: float3) -> SIMD2<Int32> { SIMD2(Int32((p.x / SmackableField.cell).rounded(.down)), Int32((p.y / SmackableField.cell).rounded(.down))) }

    /// Rompibles cuyo origen está a menos de `r` m (en planta) de p (por su posición de origen y los que se mueven).
    func near(_ p: float3, radius r: Float, into out: inout [Smackable]) {
        let c0 = key(p - float3(r, r, 0)), c1 = key(p + float3(r, r, 0))
        for y in c0.y...c1.y { for x in c0.x...c1.x {
            guard let l = grid[SIMD2(x, y)] else { continue }
            for i in l {
                let s = all[i]
                if s.state != .moving && s.state != .gone, simd_distance_squared(SIMD2(s.pos.x, s.pos.y), SIMD2(p.x, p.y)) < (r + s.boundRadius) * (r + s.boundRadius) { out.append(s) }
            }
        } }
        for s in active where simd_distance_squared(s.pos, p) < (r + s.boundRadius) * (r + s.boundRadius) { out.append(s) }
    }

    /// Los que se dibujan cerca de la cámara (todos los estados menos «desaparecido»).
    func visible(around p: float3, radius r: Float, into out: inout [Smackable]) {
        let c0 = key(p - float3(r, r, 0)), c1 = key(p + float3(r, r, 0))
        for y in c0.y...c1.y { for x in c0.x...c1.x {
            guard let l = grid[SIMD2(x, y)] else { continue }
            for i in l where all[i].state != .gone && all[i].state != .moving { out.append(all[i]) }
        } }
        for s in active where s.state == .moving { out.append(s) }
    }
}
