// El vehículo del jugador con la física del juego: une RigidBody + EngineRacer + SuspensionRacer y la entrada de
// InputPlayer, a paso fijo de 1/60 s (Scheduler::Init(1/60) en el ELF de PS2: 0x3C888889 [V]).
// Orden por paso, como BEHAVIOR_ORDER del pvehicle [V]: RIGIDBODY → INPUT → ENGINE → SUSPENSION, e integración.
// Choques con muros y suelo del cuerpo: versión propia con impulsos [I] (RigidBody::DoBarrierCollision y
// ResolveGroundCollision no se han portado línea a línea).
import simd

/// Lo que llega del teclado o del mando (InputPlayer: mGasButton, mBrakeButton, mSteerLeft/Right, freno de mano, NOS).
struct DriverInput {
    var gas: Float = 0, brake: Float = 0, steerLeft: Float = 0, steerRight: Float = 0, handBrake: Float = 0
    var nos = false, shiftUp = false, shiftDown = false, lookBack = false
}

final class PVehicle {
    static let timeStep: Float = 1.0 / 60
    /// VehicleSystem::PAD_DEAD_ZONE = 0,05 [V: ELF SLUS-21351, 0x005780D4].
    static let padDeadZone: Float = 0.05

    let specs: VehicleSpecs
    let rb: RigidBody
    let engine: EngineRacer
    let susp: SuspensionRacer
    let ground: PhysicsGround
    private(set) var controls = Controls()
    private(set) var simTime: Float = 1.0 / 60
    /// Compresión estática por eje y altura del brazo sobre el suelo en reposo (para colocar y dibujar) [I].
    let staticCompression: [Float]
    var gravity: Float { specs.rigidbody.GRAVITY }
    private var prevShiftUp = false, prevShiftDown = false
    private(set) var lastImpact: Float = 0
    /// Golpe más fuerte (Δv en m/s) desde la última lectura.
    func takeImpact() -> Float { defer { lastImpact = 0 }; return lastImpact }

    init(specs: VehicleSpecs, dimension: V3, ground: PhysicsGround) {
        self.specs = specs; self.ground = ground
        let ts = specs.tensorScale
        rb = RigidBody(mass: specs.mass, dimension: dimension, tensorScale: V3(ts.count > 0 ? ts[0] : 1, ts.count > 1 ? ts[1] : 1, ts.count > 2 ? ts[2] : 1))
        engine = EngineRacer(specs)
        susp = SuspensionRacer(specs, dimension: dimension)
        staticCompression = [susp.staticCompression(axle: 0, mass: specs.mass, gravity: specs.rigidbody.GRAVITY),
                             susp.staticCompression(axle: 1, mass: specs.mass, gravity: specs.rigidbody.GRAVITY)]
    }

    /// Altura del origen del cuerpo sobre el suelo en reposo: brazo (cara inferior) a RIDE_HEIGHT − compresión.
    var restHeight: Float { rb.dimension.y + (susp.rideHeight(0) - staticCompression[0] + susp.rideHeight(1) - staticCompression[1]) * 0.5 }

    /// Coloca el coche parado sobre el suelo (posición del mundo del motor, rumbo en radianes, Z arriba).
    func place(world p: float3, yaw: Float) {
        rb.orientation = simd_quatf(angle: -yaw, axis: V3(0, 1, 0))
        var gz = p.z
        if let g = ground.ground(x: p.x, y: p.y, z: p.z + 50, step: 0) { gz = g.z }
        rb.position = PM.toGame(float3(p.x, p.y, gz)) + V3(0, restHeight, 0)
        rb.linearVel = .zero; rb.angularVel = .zero; rb.force = .zero; rb.torque = .zero
        susp.reset(); engine.reset()
        for i in 0..<4 { susp.tires[i].setCompression(staticCompression[i / 2]) }
        controls = Controls()
    }

    /// Velocidad hacia delante (IVehicle::GetSpeed) [I: local_vel.z].
    var forwardSpeed: Float { rb.toLocal(rb.linearVel).z }
    var speed: Float { simd_length(rb.linearVel) }

    // MARK: InputPlayer::FetchInput [D: PInput.cpp]
    private func fetchInput(_ raw: DriverInput) {
        var gas = raw.gas, brake = raw.brake
        let dz = PVehicle.padDeadZone
        if gas > 1 - dz { gas = 1 }; if gas < dz { gas = 0 }
        if brake > 1 - dz { brake = 1 }; if brake < dz { brake = 0 }
        controls.nos = raw.nos
        controls.gas = gas; controls.brake = brake
        controls.handBrake = raw.handBrake > 0 ? raw.handBrake : 0
        // DoShifting (flanco de subida)
        if raw.shiftUp && !prevShiftUp { engine.shift(1) }
        if raw.shiftDown && !prevShiftDown { engine.shift(-1) }
        prevShiftUp = raw.shiftUp; prevShiftDown = raw.shiftDown
        // DoAutoReverse
        let v = forwardSpeed
        if engine.gear != Gear.reverse {
            if v < 2.5 && brake > 0 && gas == 0 { engine.shiftTo(Gear.reverse) }
        } else if v > -5 && (brake == 0 || gas > 0) { engine.shiftTo(Gear.first) }
        if engine.gear == Gear.reverse { controls.gas = brake; controls.brake = gas }
        // DoAutoBraking
        if !(gas > 0 || brake > 0) {
            if engine.gear > Gear.reverse { if v < 8 { controls.brake = 1 - PM.ramp(v, 0, 8) * 0.75 } }
            else { controls.brake = 1 - PM.ramp(-v, 0, 10) * 0.75 }
        }
        if controls.handBrake != 0 { controls.brake = 0 }
        controls.steering = raw.steerRight - raw.steerLeft
    }

    /// Un paso fijo de simulación.
    func step(_ raw: DriverInput) {
        let dT = PVehicle.timeStep
        simTime += dT
        rb.force.y += gravity * rb.mass                               // RigidBody::OnBeginFrame
        fetchInput(raw)
        engine.simulate(dT, controls: controls, susp: susp, absSpeed: speed)
        susp.simulate(dT, rb: rb, controls: controls, engine: engine, ground: ground, now: simTime)
        rb.hadCollision = false
        rb.integrate(dT)
        collideWalls()
        collideGround()
    }

    // MARK: Choques con el mundo [I]

    /// Impulso en un punto con fricción de Coulomb. `scale` = *_MOMENT_SCALE (inercia efectiva en choques) [I].
    private func applyImpact(at p: V3, normal n: V3, elasticity e: Float, friction mu: Float, scale: V3) -> Float {
        let r = p - (rb.position + rb.worldCog)
        let v = rb.pointVelocity(p)
        let vn = simd_dot(v, n)
        guard vn < 0 else { return 0 }
        func invI(_ x: V3) -> V3 { let l = rb.toLocal(x); return rb.rotate(l / (rb.inertia * scale)) }
        let kn = 1 / rb.mass + simd_dot(n, simd_cross(invI(simd_cross(r, n)), r))
        let jn = -(1 + e) * vn / kn
        var J = n * jn
        let vt = v - n * vn
        let vtl = simd_length(vt)
        if vtl > 1e-4 {
            let t = vt / vtl
            let kt = 1 / rb.mass + simd_dot(t, simd_cross(invI(simd_cross(r, t)), r))
            J -= t * min(vtl / kt, mu * jn)
        }
        rb.linearVel += J / rb.mass
        rb.angularVel += invI(simd_cross(r, J))
        rb.hadCollision = true
        return jn / rb.mass
    }

    private func collideWalls() {
        let d = rb.dimension
        let cw = PM.toWorld(rb.position)
        let walls = ground.walls(near: SIMD2(cw.x, cw.y), radius: d.z + 3)
        guard !walls.isEmpty else { return }
        let ws = specs.rigidbody
        let scale = V3(ws.WORLD_MOMENT_SCALE.count > 2 ? ws.WORLD_MOMENT_SCALE[0] : 1, ws.WORLD_MOMENT_SCALE.count > 2 ? ws.WORLD_MOMENT_SCALE[1] : 1, ws.WORLD_MOMENT_SCALE.count > 2 ? ws.WORLD_MOMENT_SCALE[2] : 1)
        let c2 = SIMD2(cw.x, cw.y)
        let zLo = cw.z - d.y, zHi = cw.z + d.y
        for _ in 0..<2 {                     // dos pasadas por si toca dos muros a la vez
            var best: (depth: Float, n: SIMD2<Float>, p: V3)? = nil
            for sx in [-1, 1] as [Float] { for sz in [-1, 1] as [Float] {
                let pw = PM.toWorld(rb.position + rb.rotate(V3(sx * d.x, 0, sz * d.z)))
                let p2 = SIMD2(pw.x, pw.y)
                for w in walls where w.zMax > zLo + 0.2 && w.zMin < zHi {
                    let s = w.b - w.a, r = p2 - c2
                    let den = r.x * s.y - r.y * s.x
                    if abs(den) < 1e-9 { continue }
                    let q = w.a - c2
                    let t = (q.x * s.y - q.y * s.x) / den, u = (q.x * r.y - q.y * r.x) / den
                    guard t >= 0, t <= 1, u >= 0, u <= 1 else { continue }
                    var n = simd_normalize(SIMD2(-s.y, s.x))
                    if simd_dot(c2 - w.a, n) < 0 { n = -n }
                    let depth = -simd_dot(p2 - w.a, n)
                    if depth > 0 && (best == nil || depth > best!.depth) { best = (depth, n, PM.toGame(pw)) }
                }
            } }
            guard let b = best else { break }
            let n3 = PM.toGame(float3(b.n.x, b.n.y, 0))
            rb.position += n3 * (b.depth + 0.005)
            let closing = rb.pointVelocity(b.p)
            let dv = applyImpact(at: b.p, normal: n3, elasticity: ws.WALL_ELASTICITY.first ?? 0, friction: ws.WALL_FRICTION.first ?? 0.5, scale: scale)
            lastImpact = max(lastImpact, dv)
            // SuspensionRacer::OnCollision: menos dirección tras el golpe y giro de morro contra el muro [D]
            if dv > 10 { susp.collisionTimer = max(PM.ramp(dv, 10, 40), susp.collisionTimer) }
            if simd_length_squared(closing) < 56.25 && simd_length_squared(rb.linearVel) < 6.25 && simd_dot(n3, rb.forward) <= 0 {
                if simd_dot(b.p - rb.position, rb.forward) > d.z * 0.75 {
                    let dt = simd_dot(n3, rb.right)
                    susp.wallNoseTurn = (dt > 0 ? 1 : -1) - dt
                }
            }
        }
    }

    /// Esquinas de la caja contra el suelo (techo o bajos tocando): empuje e impulso con GROUND_FRICTION [I].
    private func collideGround() {
        let d = rb.dimension, ws = specs.rigidbody
        let scale = V3(ws.GROUND_MOMENT_SCALE.count > 2 ? ws.GROUND_MOMENT_SCALE[0] : 1, ws.GROUND_MOMENT_SCALE.count > 2 ? ws.GROUND_MOMENT_SCALE[1] : 1, ws.GROUND_MOMENT_SCALE.count > 2 ? ws.GROUND_MOMENT_SCALE[2] : 1)
        var deepest: (d: Float, p: V3, n: V3)? = nil
        for sx in [-1, 1] as [Float] { for sy in [-1, 1] as [Float] { for sz in [-1, 1] as [Float] {
            let p = rb.position + rb.rotate(V3(sx * d.x * 0.9, sy * d.y, sz * d.z * 0.9))
            let w = PM.toWorld(p)
            guard let g = ground.ground(x: w.x, y: w.y, z: w.z, step: 1.0) else { continue }
            let pen = g.z - w.z
            if pen > 0 && (deepest == nil || pen > deepest!.d) { deepest = (pen, p, PM.toGame(g.normal)) }
        } } }
        guard let c = deepest else { return }
        rb.position.y += c.d
        _ = applyImpact(at: c.p, normal: c.n.y < 0 ? -c.n : c.n, elasticity: ws.GROUND_ELASTICITY.first ?? 0, friction: ws.GROUND_FRICTION.first ?? 0.5, scale: scale)
    }
}
