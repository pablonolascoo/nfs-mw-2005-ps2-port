// Choques del juego entre coches (jugador, rivales, tráfico, policía) y contra los rompibles del mundo.
// Port de la respuesta de RigidBody [D: Physics/Behaviors/RigidBody.cpp]:
//   OnObjectOverlap        → pares cuyas esferas envolventes se tocan; volúmenes PrimVsObjects de bounds.json [D][V]
//   Geometry::FindIntersection → Crash/CrashGeometry.swift (OBB/esferas) [I: Geometry.cpp vacío en la decomp]
//   ResolveObjectCollision → fricción Ks = √(μs_A·μs_B), Kd = √(μk_A·μk_B), plano μ = (min(Ks, Kd), Ks); elasticidad de
//                            cada cuerpo = |normal en sus ejes ⊙ OBJ_ELASTICITY|; ModifyCollision (OBJ_MOMENT_SCALE: xyz
//                            escala la inercia, w > 0 escala la masa; IMMOBILE_OBJECT_COLLISIONS; pegado al mundo con
//                            fuerza de rotura); Separate (reparto por masas o el móvil entero); Moment::React → impulso [D]
//   Moment::React          → impulso de choque con fricción de Coulomb estática/dinámica [I: no está decompilado]
//   COLLISION_INFO / ECollision → CrashEvent: daños (Crash/Damage.swift), sonidos de golpe (SFXWorld stitches), policía.
// La física del jugador y de los rivales es la del juego (PVehicle, espacio «Bond»); la de la IA es cinemática con un
// deslizamiento en planta tras el golpe (Crash/CrashAI.swift); los rompibles son cuerpos libres (Crash/Smackables.swift).
// Se ejecuta una vez por fotograma tras mover a todos (AIWorld.update), en el mundo del motor (Z arriba).
import Foundation
import simd

/// Un choque resuelto (COLLISION_INFO del juego [D]).
struct CrashEvent {
    enum Kind { case carCar, carSmackable }
    var kind: Kind
    var a: CrashBody, b: CrashBody
    var point: float3
    var normal: float3            // hacia A
    var impulse: Float            // N·s
    var closing: Float            // m/s a lo largo de la normal
    var sliding: Bool
}

/// Un cuerpo del choque. Envuelve al dueño (coche con física, coche de la IA o rompible) y da su marco y su dinámica.
final class CrashBody {
    enum Owner { case car(Car), ai(AIVehicle), smack(Smackable) }
    enum Role { case player, human, racer, traffic, cop, smackable }
    let owner: Owner
    let role: Role
    let rb: CrashRBSpecs
    let mass: Float
    let inertia: V3               // diagonal en ejes del cuerpo (derecha, arriba, adelante)
    let root: V3                  // medias medidas del cuerpo (derecha, arriba, adelante) para las zonas de daño
    let defs: [CrashPrimDef]
    let damageSpecs: DamageSpecs?
    // Marco de este paso
    var origin = float3(0, 0, 0)
    var R = float3x3(1)           // columnas: derecha, arriba, adelante (mundo)
    var prims: [CrashPrim] = []
    var radius: Float = 3
    var cg = float3(0, 0, 0)
    var lin = float3(0, 0, 0), ang = float3(0, 0, 0)
    var dvSum = float3(0, 0, 0), dwSum = float3(0, 0, 0)

    init(owner: Owner, role: Role, rb: CrashRBSpecs, mass: Float, inertia: V3, root: V3, defs: [CrashPrimDef], damage: DamageSpecs?) {
        self.owner = owner; self.role = role; self.rb = rb; self.mass = max(1, mass); self.inertia = inertia; self.root = root
        self.defs = defs; damageSpecs = damage
    }

    var isAI: AIVehicle? { if case .ai(let v) = owner { return v }; return nil }
    var isCar: Car? { if case .car(let c) = owner { return c }; return nil }
    var isSmack: Smackable? { if case .smack(let s) = owner { return s }; return nil }
    var planar: Bool { isAI != nil }

    /// Marco, volúmenes y velocidades de este paso.
    func refresh() {
        switch owner {
        case .car(let c):
            guard let v = c.vehicle else { return }
            let rb = v.rb
            R = float3x3(PM.toWorld(rb.right), PM.toWorld(rb.up), PM.toWorld(rb.forward))
            origin = PM.toWorld(rb.position)
            cg = PM.toWorld(rb.position + rb.worldCog)
            lin = PM.toWorld(rb.linearVel)
            ang = -PM.toWorld(rb.angularVel)          // pseudovector: el cambio de mano invierte el signo
        case .ai(let a):
            let f = float3(cos(a.yaw), sin(a.yaw), 0)
            R = float3x3(float3(f.y, -f.x, 0), float3(0, 0, 1), f)
            origin = a.pos + float3(0, 0, root.y)     // la caja raíz apoyada en el suelo [I]
            cg = origin
            let v2 = a.planarVel
            lin = float3(v2.x, v2.y, 0)
            ang = float3(0, 0, a.dyn ? a.yawRate : 0)
        case .smack(let s):
            R = s.R
            origin = s.pos
            cg = s.cg
            lin = s.vel; ang = s.ang
        }
        if case .smack(let s) = owner { prims = s.prims() }
        else {
            prims = defs.map { d in
                let c = origin + R * PM.toWorldModel(d.center)
                let ax = float3x3(R * PM.toWorldModel(d.rot.act(V3(1, 0, 0))), R * PM.toWorldModel(d.rot.act(V3(0, 1, 0))), R * PM.toWorldModel(d.rot.act(V3(0, 0, 1))))
                return CrashPrim(c: c, ax: ax, e: d.half, sphere: d.sphere, r: d.sphere ? d.radius : simd_length(d.half), surface: d.surface)
            }
        }
        radius = prims.map { simd_distance($0.c, origin) + $0.r }.max() ?? 3
        dvSum = .zero; dwSum = .zero
    }

    func velocity(at p: float3) -> float3 { lin + simd_cross(ang, p - cg) }

    /// I⁻¹ en el mundo con la escala de inercia de ModifyCollision. La IA solo gira en planta (eje Z).
    func invI(_ x: float3, scale: V3) -> float3 {
        if case .smack(let s) = owner { return s.invI(x, scale: scale) }
        if planar {
            let izz = inertia.y * max(scale.y, 0.01)
            return float3(0, 0, x.z / max(izz, 1))
        }
        let l = R.transpose * x
        return R * (l / simd_max(inertia * scale, V3(repeating: 1e-3)))
    }

    /// Aplica el cambio de velocidad (mundo) al dueño.
    func apply(dv: float3, dw: float3) {
        lin += dv; ang += dw
        dvSum += dv; dwSum += dw
        switch owner {
        case .car(let c):
            guard let v = c.vehicle else { return }
            v.rb.linearVel += PM.toGame(dv)
            v.rb.angularVel += -PM.toGame(dw)
        case .ai: break                                // se decide tras todos los choques (CrashWorld.settleAI)
        case .smack(let s): s.vel += dv; s.ang += dw
        }
    }

    func move(_ d: float3, collision: CollisionWorld) {
        origin += d; cg += d
        for i in prims.indices { prims[i].c += d }
        switch owner {
        case .car(let c): c.vehicle?.rb.position += PM.toGame(d)
        case .ai(let a):
            let to = a.pos + float3(d.x, d.y, 0)
            if !collision.hitsWall(from: a.pos + float3(0, 0, 0.3), to: to + float3(0, 0, 0.3)) { a.pos = to }
        case .smack(let s): s.pos += d
        }
    }
}

extension PM {
    /// Espacio del modelo del juego (x derecha, y arriba, z adelante) → coordenadas del cuerpo en el mundo con columnas
    /// (derecha, arriba, adelante): es la identidad por componentes.
    @inline(__always) static func toWorldModel(_ v: V3) -> float3 { v }
}

final class CrashWorld {
    static var data: CrashData?
    let data: CrashData
    unowned let ai: AIWorld
    let smackables: SmackableField
    let breakers: PursuitBreakers
    var time: Float = 0
    /// Coches con la física del juego este fotograma (jugador, pantalla partida, rivales). Lo rellena el motor.
    var cars: [(car: Car, role: CrashBody.Role)] = []
    /// Cuerpo del jugador de la prueba --traffic-test (coche de la IA que hace de jugador).
    var testPlayer: AIVehicle?
    var enabled = true
    var renderer: SmackableRenderer?
    var events: [CrashEvent] = []                 // los de este fotograma (pruebas, sonido)
    var log: [String] = []
    var onEvent: ((CrashEvent) -> Void)?
    var onMessage: ((String, UInt32) -> Void)?    // texto del HUD + icono
    private var contactsPrev = Set<Int>(), contactsNow = Set<Int>()
    private var rng = SplitMix(seed: 0xC4A5)
    private(set) var lastCost: Double = 0         // ms del último paso
    let debug = ProcessInfo.processInfo.environment["ROCKPORT_DEBUG_CRASH"] != nil

    init(ai: AIWorld, data: CrashData) {
        self.ai = ai; self.data = data
        CrashWorld.data = data
        smackables = SmackableField(data: data)
        breakers = PursuitBreakers(data: data, field: smackables)
        for r in data.report { print("Choques: \(r)") }
        print("Choques: \(data.carBounds.count) coches con volúmenes · \(smackables.all.count) rompibles\(smackables.enabled ? "" : " (fijos)") · \(breakers.list.count) derrumbes de persecución")
    }

    // MARK: Cuerpos

    private var bodyCache: [ObjectIdentifier: CrashBody] = [:]

    private func body(car c: Car, role: CrashBody.Role) -> CrashBody? {
        guard let v = c.vehicle else { return nil }
        let id = ObjectIdentifier(c)
        if let b = bodyCache[id], b.role == role { return b }
        let model = v.specs.model
        let spec = data.vehicle(model)
        let dim = v.rb.dimension
        let bounds = data.carPrims(model: model, fallbackHalf: dim)
        // Inercia de la física del juego (RigidBody, ejes x, y, z = derecha, arriba, adelante)
        let b = CrashBody(owner: .car(c), role: role, rb: spec?.rb ?? CrashRBSpecs(), mass: v.rb.mass, inertia: v.rb.inertia,
                          root: dim, defs: bounds.prims, damage: spec?.damage)
        bodyCache[id] = b
        return b
    }

    private func body(ai v: AIVehicle, role: CrashBody.Role) -> CrashBody {
        let id = ObjectIdentifier(v)
        if let b = bodyCache[id], b.role == role { return b }
        let spec = v.crashSpecs
        let fb = V3(v.model.halfWidth, v.model.height * 0.5, v.model.halfLength)
        let bounds = data.carPrims(model: v.model.name, fallbackHalf: fb)
        let m = spec?.mass ?? 1500
        let w = 2 * bounds.root.x, h = 2 * bounds.root.y, l = 2 * bounds.root.z
        let ts = spec?.tensorScale ?? V3(1, 1, 1)
        // Inertia::Box × TENSOR_SCALE [D]
        let inertia = V3((h * h + l * l) / 12, (w * w + l * l) / 12, (w * w + h * h) / 12) * m * ts
        let b = CrashBody(owner: .ai(v), role: role, rb: spec?.rb ?? CrashRBSpecs(), mass: m, inertia: inertia, root: bounds.root,
                          defs: bounds.prims, damage: spec?.damage)
        bodyCache[id] = b
        return b
    }

    private func body(smack s: Smackable) -> CrashBody {
        let id = ObjectIdentifier(s)
        if let b = bodyCache[id] { return b }
        let b = CrashBody(owner: .smack(s), role: .smackable, rb: s.rb, mass: s.mass, inertia: s.inertia, root: simd_abs(PM.toWorld(s.root)),
                          defs: s.localPrims, damage: nil)
        bodyCache[id] = b
        return b
    }

    // MARK: Paso

    func step(dt: Float) {
        guard enabled, dt > 0 else { return }
        let t0 = CACurrentMediaTimeShim.now()
        time += dt
        events.removeAll(keepingCapacity: true)
        contactsNow.removeAll(keepingCapacity: true)
        var bodies: [CrashBody] = []
        for (c, role) in cars { if let b = body(car: c, role: role) { b.refresh(); bodies.append(b) } }
        if let tp = testPlayer { let b = body(ai: tp, role: .player); b.refresh(); bodies.append(b) }
        for v in ai.vehicles {
            let b = body(ai: v, role: v.kind == .cop ? .cop : .traffic)
            b.refresh(); bodies.append(b)
        }
        // Coches contra coches (O(n²) con esferas: ~30 coches = 435 pares, casi todos descartados por distancia)
        for i in bodies.indices {
            for j in (i + 1)..<max(i + 1, bodies.count) {
                let a = bodies[i], b = bodies[j]
                let rr = a.radius + b.radius
                if simd_distance_squared(a.origin, b.origin) > rr * rr || abs(a.origin.z - b.origin.z) > 3 { continue }
                // Dos coches de la IA en sus carriles: sin respuesta (el seguidor de carril ya frena) salvo choque de verdad
                if a.planar && b.planar, !(a.isAI!.dyn || b.isAI!.dyn), simd_length(a.lin - b.lin) < 3, a.role != .player, b.role != .player { continue }
                collide(a, b, kind: .carCar)
            }
        }
        // Coches contra rompibles
        if smackables.enabled {
            var near: [Smackable] = []
            for a in bodies {
                let moving = simd_length(a.lin) > 0.5 || (a.isAI?.dyn ?? false)
                guard moving else { continue }
                near.removeAll(keepingCapacity: true)
                smackables.near(a.origin, radius: a.radius + 1, into: &near)
                for s in near {
                    let b = body(smack: s)
                    b.refresh()
                    collide(a, b, kind: .carSmackable)
                }
            }
        }
        settleAI(bodies)
        // Rompibles en movimiento
        for s in smackables.all where s.state == .moving && !s.listed { s.listed = true; smackables.active.append(s) }
        for s in smackables.active { s.step(dt: dt, ground: ai.collision) }
        smackables.active.removeAll { if $0.state != .moving { $0.listed = false; return true }; return false }
        updateSmackableLifetime(dt: dt)
        breakers.update(dt: dt, world: self)
        contactsPrev = contactsNow
        lastCost = (CACurrentMediaTimeShim.now() - t0) * 1000
        // limpiar la caché de cuerpos de dueños que ya no existen
        if bodyCache.count > 400 {
            let live = Set(bodies.map { ObjectIdentifier($0) })
            bodyCache = bodyCache.filter { live.contains(ObjectIdentifier($0.value)) || $0.value.isSmack != nil }
            if bodyCache.count > 800 { bodyCache.removeAll() }
        }
    }

    /// Vida de los rompibles sueltos: KILL_OFF_SCREEN y RESPAWN_TIME [I: nombres de los atributos].
    private var lifeTick: Float = 0
    private func updateSmackableLifetime(dt: Float) {
        lifeTick += dt
        guard lifeTick > 0.5 else { return }
        let step = lifeTick; lifeTick = 0
        for s in smackables.all where s.state != .attached && s.state != .loose {
            let far = simd_distance(s.pos, ai.center) > 40 && !ai.onScreen(s.pos, radius: s.boundRadius)
            if s.state == .gone {
                s.goneTime += step
                if s.goneTime > s.type.respawnTime && !ai.onScreen(s.pos0, radius: s.boundRadius) && simd_distance(s.pos0, ai.center) > 60 {
                    s.respawn(); breakers.reset(containing: s)
                }
            } else if far {
                s.offscreen += step
                if s.offscreen > max(1, s.type.killOffScreen) { s.state = .gone; s.goneTime = 0 }
            } else { s.offscreen = 0 }
        }
    }

    // MARK: Respuesta (ResolveObjectCollision)

    private func immobile(_ x: CrashBody, against other: CrashBody) -> (Bool, Float) {
        // ModifyCollision [D]: contra un cuerpo móvil, IMMOBILE_OBJECT_COLLISIONS o pegado al mundo (con fuerza de rotura)
        if let s = x.isSmack {
            if s.state == .attached { return (true, s.type.detachForce) }
            return (false, 0)
        }
        if x.rb.immobileObjectCollisions { return (true, 0) }
        if let a = x.isAI, a.mode == .parked, a.copRole == .roadblock, !a.dyn { return (false, 0) }
        return (false, 0)
    }

    private func pairKey(_ a: CrashBody, _ b: CrashBody) -> Int {
        let x = ObjectIdentifier(a).hashValue, y = ObjectIdentifier(b).hashValue
        return x < y ? x &* 31 &+ y : y &* 31 &+ x
    }

    private func collide(_ a: CrashBody, _ b: CrashBody, kind: CrashEvent.Kind) {
        // El contacto más profundo entre sus volúmenes [I: el juego resuelve cada par de volúmenes por separado]
        var best: CrashGeometry.Contact? = nil
        for pa in a.prims { for pb in b.prims {
            let rr = pa.r + pb.r
            if simd_distance_squared(pa.c, pb.c) > rr * rr { continue }
            if let c = CrashGeometry.intersect(pa, pb), best == nil || c.depth > best!.depth { best = c }
        } }
        guard let c = best, c.depth > 1e-4 else { return }
        contactsNow.insert(pairKey(a, b))
        resolve(a, b, c, kind: kind)
    }

    private func elasticity(_ x: CrashBody, _ n: float3) -> Float {
        let l = x.R.transpose * n
        return simd_length(l * x.rb.objElasticity)
    }

    private func resolve(_ a: CrashBody, _ b: CrashBody, _ c: CrashGeometry.Contact, kind: CrashEvent.Kind) {
        let n = c.n
        var p = c.p
        // Fricción y elasticidad [D]
        let Ks = sqrt(a.rb.objFriction.x * b.rb.objFriction.x), Kd = sqrt(a.rb.objFriction.y * b.rb.objFriction.y)
        let us = Ks, uk = min(Ks, Kd)
        let e = 0.5 * (elasticity(a, n) + elasticity(b, n))     // [I: Moment::React combina las dos]
        // ModifyCollision [D]
        var (immA, breakA) = immobile(a, against: b)
        var (immB, breakB) = immobile(b, against: a)
        if immA && immB { if breakA > 0 { immA = false }; if breakB > 0 { immB = false } }
        let msA = a.rb.objMomentScale, msB = b.rb.objMomentScale
        let mA = a.mass * (msA.w > 0 ? msA.w : 1), mB = b.mass * (msB.w > 0 ? msB.w : 1)
        let scA = V3(msA.x, msA.y, msA.z), scB = V3(msB.x, msB.y, msB.z)
        // Separate [D]
        guard c.depth > 1e-4, !(immA && immB) else { return }
        if immA != immB {
            if immB { a.move(n * c.depth, collision: ai.collision); p += n * c.depth * 0.5 }
            else { b.move(-n * c.depth, collision: ai.collision); p -= n * c.depth * 0.5 }
        } else {
            let moveB = a.mass / (a.mass + b.mass), moveA = 1 - moveB
            a.move(n * (moveA * c.depth), collision: ai.collision)
            b.move(-n * (moveB * c.depth), collision: ai.collision)
        }
        // Moment::React [I]: impulso normal con restitución y fricción de Coulomb
        func solve(_ immA: Bool, _ immB: Bool) -> (J: float3, jn: Float, vn: Float, sliding: Bool)? {
            let rA = p - a.cg, rB = p - b.cg
            let vrel = a.velocity(at: p) - b.velocity(at: p)
            let vn = simd_dot(vrel, n)
            guard vn < 0 else { return nil }
            func k(_ x: CrashBody, _ r: float3, _ m: Float, _ sc: V3, _ dir: float3, _ imm: Bool) -> Float {
                imm ? 0 : 1 / m + simd_dot(dir, simd_cross(x.invI(simd_cross(r, dir), scale: sc), r))
            }
            let kn = k(a, rA, mA, scA, n, immA) + k(b, rB, mB, scB, n, immB)
            guard kn > 1e-9 else { return nil }
            let jn = -(1 + e) * vn / kn
            var J = n * jn
            var sliding = false
            let vt = vrel - n * vn, vtl = simd_length(vt)
            if vtl > 1e-3 {
                let t = vt / vtl
                let kt = k(a, rA, mA, scA, t, immA) + k(b, rB, mB, scB, t, immB)
                if kt > 1e-9 {
                    let need = vtl / kt
                    if need <= us * jn { J -= t * need } else { J -= t * (uk * jn); sliding = true }
                }
            }
            return (J, jn, vn, sliding)
        }
        guard var r = solve(immA, immB) else { return }
        // Rotura del pegado al mundo: si el impulso supera DETACH_FORCE el rompible se suelta y se recalcula [I]
        if immB, breakB > 0 || breakB == 0, let s = b.isSmack, s.state == .attached, simd_length(r.J) > breakB {
            s.detach(now: time); immB = false
            if let r2 = solve(immA, false) { r = r2 }
        }
        if immA, breakA > 0 || breakA == 0, let s = a.isSmack, s.state == .attached, simd_length(r.J) > breakA {
            s.detach(now: time); immA = false
            if let r2 = solve(false, immB) { r = r2 }
        }
        if let s = b.isSmack, s.state == .loose || s.state == .sleeping, !immB { s.detach(now: time) }
        if let s = a.isSmack, s.state == .loose || s.state == .sleeping, !immA { s.detach(now: time) }
        let rA = p - a.cg, rB = p - b.cg
        if !immA { a.apply(dv: r.J / mA, dw: a.invI(simd_cross(rA, r.J), scale: scA)) }
        if !immB { b.apply(dv: -r.J / mB, dw: b.invI(simd_cross(rB, -r.J), scale: scB)) }
        let ev = CrashEvent(kind: kind, a: a, b: b, point: p, normal: n, impulse: simd_length(r.J), closing: -r.vn, sliding: r.sliding)
        events.append(ev)
        handle(ev, firstContact: !contactsPrev.contains(pairKey(a, b)), momentMassA: mA, momentMassB: mB)
        onEvent?(ev)
    }

    // MARK: IA tras los choques

    /// El coche de la IA es cinemático: con un golpe pequeño solo cambia su velocidad; con uno fuerte pasa a deslizarse [I].
    private func settleAI(_ bodies: [CrashBody]) {
        for b in bodies {
            guard let v = b.isAI, simd_length(b.dvSum) > 0.01 || abs(b.dwSum.z) > 0.01 else { continue }
            if b.role == .player { v.speed = max(0, simd_dot(b.lin, v.fwd)); continue }   // coche de prueba: sigue su carril
            let f2 = float2(cos(v.yaw), sin(v.yaw)), r2 = float2(sin(v.yaw), -cos(v.yaw))
            let dv2 = float2(b.dvSum.x, b.dvSum.y)
            let lateral = abs(simd_dot(dv2, r2)), spin = abs(b.dwSum.z)
            let newVel = float2(b.lin.x, b.lin.y)
            if v.dyn || lateral > 1.5 || spin > 0.35 || simd_length(dv2) > 4 || v.mode == .parked {
                v.beginDynamic(vel: newVel, yawRate: (v.dyn ? v.yawRate : 0) + b.dwSum.z)
                v.lastCrash = time
                if v.kind == .traffic { v.crashed = true; v.mode = .parked; v.speed = 0 }
            } else {
                v.speed = max(0, simd_dot(newVel, f2))
            }
        }
    }

    // MARK: Consecuencias de cada choque

    private func stitchLevel(_ closing: Float) -> String { closing < 4 ? "VLIT" : closing < 8 ? "LIT" : closing < 14 ? "MED" : "HRD" }

    private func handle(_ ev: CrashEvent, firstContact: Bool, momentMassA: Float, momentMassB: Float) {
        let a = ev.a, b = ev.b
        ai.stats.carImpacts += ev.kind == .carCar ? (firstContact ? 1 : 0) : 0
        // Daños [D: DamageVehicle::OnCollision]: speed < 1 → nada; fuerza = impulso/masa del Moment × masa, ×2 contra objetos
        for (x, other, n, mm) in [(a, b, ev.normal, momentMassA), (b, a, -ev.normal, momentMassB)] {
            guard ev.closing >= 1, let specs = x.damageSpecs else { continue }
            if other.isSmack != nil {
                // DamageVehicle: NO_CAR_EFFECT del rompible; DamageCopCar: solo si es inmóvil o pesa > 2000 kg [D]
                guard let s = other.isSmack, !s.type.noCarEffect || s.state == .attached else { continue }
                if x.role == .cop, !(s.state == .attached || s.mass > 2000) { continue }
            }
            var force = ev.impulse / mm * x.mass
            force += force    // impact_force += impact_force (choque contra otro objeto) [D]
            // SUPPRESS_DIST: sin daños lejos de la cámara [D]
            if specs.suppressDist > 0, simd_distance(x.origin, ai.center) > specs.suppressDist * 4 { continue }
            let arm = x.R.transpose * (ev.point - x.origin)
            let nl = x.R.transpose * n
            switch x.owner {
            case .car(let c):
                guard let h = c.damage.impact(specs: specs, arm: arm, normal: nl, dim: x.root, force: force) else { continue }
                c.damage.shock(impulse: force, mass: x.mass, specs: specs)
                if h.newDamage { c.applyDamageVisuals(); if debug { log("daño \(c.specs?.model ?? "?") zona \(h.zone) nivel \(c.damage.zones[h.zone.rawValue])") } }
            case .ai(let v):
                let wasDestroyed = v.damage.destroyed
                guard let h = v.damage.impact(specs: specs, arm: arm, normal: nl, dim: x.root, force: force,
                                              canDamageVisuals: v.model.hasDamageParts) else { continue }
                v.damage.shock(impulse: force, mass: x.mass, specs: specs)
                if debug { log(String(format: "golpe %@ zona %@ ratio %.2f vida %.2f", v.typeName, "\(h.zone)", h.ratio, v.damage.total)) }
                if v.kind == .cop && !wasDestroyed && v.damage.destroyed { copDestroyed(v, by: other) }
            case .smack: break
            }
        }
        // Policía y tráfico: lo que hace el jugador (AIPerpVehicle::OnCausedCollision [D])
        for (x, other) in [(a, b), (b, a)] where x.role == .player || x.role == .human {
            if let v = other.isAI {
                if v.kind == .traffic {
                    if firstContact {
                        ai.stats.playerHitsTraffic += 1
                        if x.role == .player, ev.closing >= AITables.mph(5) { ai.police.reportTrafficHit() }
                    }
                } else if v.kind == .cop, x.role == .player {
                    if firstContact { ai.stats.playerHitsCops += 1; ai.police.reportCopHit(v, closing: ev.closing) }
                    if ev.closing > 4.47 { ai.police.notifyCopDamaged(v) }     // Tweak_MinAICausalityHitSpeed ≈ 10 mph [I]
                }
            }
            if let s = other.isSmack, firstContact {
                ai.stats.smackablesHit += 1
                if !s.hitByPlayer { s.hitByPlayer = true; if x.role == .player { ai.police.addPropertyDamage(s.type.costToState) } }
                breakers.smackableHit(s, byPlayer: x.role == .player, world: self)
            }
        }
        // Rompibles golpeados por la IA también cuentan para los derrumbes (la policía puede tirarlos) [I]
        if ev.kind == .carSmackable, let s = (a.isSmack ?? b.isSmack), s.state == .moving { breakers.smackableHit(s, byPlayer: false, world: self) }
        // Sonido [D: STICH_PlayBack con los «stitches» de INGAMEB.BUN; elección por velocidad propia [I]]
        if firstContact || ev.closing > 6 {
            let lvl = stitchLevel(ev.closing)
            var prefixes: [String] = []
            if ev.kind == .carCar {
                let x = a.isCar != nil || a.role == .player ? a : b
                let fwd = abs(simd_dot(ev.normal, x.R.columns.2)) > 0.7
                prefixes.append("CRSH_CAR_2_CAR_\(fwd ? "FRNT" : "SIDE")_\(lvl)")
            } else if let s = a.isSmack ?? b.isSmack {
                prefixes.append("CRSH_CAR_2_SMCKBLE_\(lvl == "HRD" ? "MED" : lvl)")
                if let k = CrashSounds.smackable(s.type.name) { prefixes.append("SMK_\(k)vsCAR_\(ev.closing < 8 ? "LIT" : "HRD")") }
            }
            CrashSounds.play(prefixes, at: ev.point, velocity: (a.lin + b.lin) * 0.5)
        }
    }

    private func copDestroyed(_ v: AIVehicle, by other: CrashBody) {
        v.lights = false
        if !v.dyn { v.beginDynamic(vel: v.planarVel, yawRate: 0) }
        ai.police.notifyCopDestroyed(v)
        log("policía destruido: \(v.typeName) (\(ai.stats.copsDestroyed) en total)")
    }

    /// Un derrumbe inmoviliza a este policía (MBreakerStopCops) [D: mensaje], cuenta como destruido [I].
    func immobilize(_ v: AIVehicle) {
        guard v.kind == .cop, !v.damage.destroyed else { return }
        v.damage.destroy()
        v.immobilized = 6
        ai.stats.copsImmobilized += 1
        copDestroyed(v, by: body(ai: v, role: .cop))
    }

    func log(_ s: String) {
        log.append(String(format: "%.2f s: ", time) + s)
        if debug { print("  choque · " + s) }
        if log.count > 400 { log.removeFirst(100) }
    }
}

/// Sonidos de golpe: stitches del disco por prefijo (SFXWorld) y un registro para que el detector de golpes del coche
/// (SFXCarSound) no repita el mismo golpe.
enum CrashSounds {
    private(set) static var recent: [(pos: float3, time: Double)] = []

    static func play(_ prefixes: [String], at p: float3, velocity: float3) {
        let now = CACurrentMediaTimeShim.now()
        recent.removeAll { now - $0.time > 0.5 }
        recent.append((p, now))
        let sfx = SFXWorld.shared
        let sp = sfx.space(at: p, velocity: velocity, ref: 12)
        var rng = SplitMix(seed: UInt64(bitPattern: Int64(p.x * 31 + p.y * 17 + Float(now))))
        for pre in prefixes { sfx.playStitch(prefix: pre, space: sp, rng: &rng) }
    }

    /// ¿Ya sonó un golpe del sistema de choques cerca de p hace menos de 0,35 s?
    static func playedRecently(near p: float3) -> Bool {
        let now = CACurrentMediaTimeShim.now()
        return recent.contains { now - $0.time < 0.35 && simd_distance($0.pos, p) < 8 }
    }

    /// Tipo de rompible → nombre de sus stitches SMK_<X>vsCAR/vsWRLD [I: el juego lo decide por los EventSequencer del
    /// smackable, no exportados; esta tabla empareja por el material del objeto].
    static func smackable(_ t: String) -> String? {
        switch t {
        case "cone", "pylon": return "CONE"
        case "mediummetalpost", "parkingarmpost", "speed_trap_camera", "largesign": return "MTL_SIGN"
        case "largemetalpost", "trafficlight", "lightfixture", "largemetalsupport": return "LAMP_LRG"
        case "trafficcablelight", "traffic_cable": return "LAMP_MED"
        case "crsh_barrel", "crsh_barrel_frag", "crsh_barrel_lid": return "WTR_DRUM_FUL"
        case "oil_drum": return "OILDRUM"
        case "garbg_can", "recyc_bin": return "GRBG_CAN"
        case "garbg_bag": return "GRBG_BAG"
        case "dumpster": return "DUMPSTER"
        case "chlink_fnc", "metal_gate", "rack": return "CHNLNK"
        case "wood_slat_fence", "picket_fence", "woodgate": return "WD_FENCE"
        case "bench", "bench_mtl_bar", "chair", "lounge_chr": return "SEATS"
        case "lwn_chr": return "LWN_CHR"
        case "umb_table", "umbrella": return "UMBRELLA"
        case "pic_table", "table", "table_frag": return "WD_FURN"
        case "crate", "cardboard_box": return "CRATE"
        case "sawhorse", "roadblock": return "WD_ROAD_BLK"
        case "parking_mtr": return "PRK_MTR"
        case "payphone", "ph_booth": return "PHONE"
        case "pop_mach": return "POP_MACH"
        case "vend_mach", "ice_box": return "VEND_MACH"
        case "news_box", "mtl_box", "tix_mach": return "MTL_BOX"
        case "firehydrant": return "HYDRNT"
        case "tire": return "TIRE"
        case "stump", "log", "plank": return "LOG"
        case "shrub", "tree": return "TREE"
        case "potty": return "PORTPOTTY"
        case "glass", "largeglass", "glassshatter1", "storefront": return "GLS_LRG"
        case "rm_glass", "gls_dr", "gls_toll", "glass_frag": return "GLS_MED"
        case "golfcart": return "GOLFCART"
        case "bicycle": return "BIKE"
        case "sailboat", "surfboard": return "BOAT"
        case "mast", "golf_flag": return "MAST"
        case "lightwoodenpost", "mediumwoodenpost", "smallwoodroofsupport", "woodsupport": return "WD_POST_LT"
        case "largewoodenpost", "woodroofsupport", "scaffolding", "woodenscaffolding": return "WD_POST_HVY"
        case "kiosk", "busstopsmack", "panel", "billboard", "fishmarketsign", "campuskiosk": return "PANEL"
        case "propanetank", "watertowercontainer": return "WTR_DRUM_EMP"
        default: return "MTL_FRAG"
        }
    }
}
