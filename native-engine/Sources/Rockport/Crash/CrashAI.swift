// Coches de la IA tras un choque: el seguidor de carril (AIVehicle) es cinemático; un golpe fuerte lo pasa a un cuerpo
// rígido en planta (posición, rumbo, velocidad y giro) que se desliza con la fricción de los neumáticos y rebota en los
// muros hasta pararse [I: el juego usa su física completa (SuspensionTraffic/SuspensionSimple), aquí una versión plana].
//  · Tráfico: se queda parado tras el accidente (AIActionTraffic ACCIDENT_OVER [D]).
//  · Policía: si no está destruida, al pararse vuelve a la red (AIActionGetUnstuck [D]) y sigue; destruida
//    (DamageVehicle mDamageTotal > 1 → EVehicleDestroyed [D]) se queda quieta, sin luces, frenando a 0,25 si va a más de
//    2,5 m/s (AIActionTooDamaged [D]); un derrumbe la deja inmovilizada (MBreakerStopCops [D: mensaje]).
import Foundation
import simd

extension AIVehicle {
    /// Masa y tensor del pvehicle (physics.json) [V].
    var crashSpecs: VehicleCrashSpecs? { CrashWorld.data?.vehicle(typeName) ?? CrashWorld.data?.vehicle(model.name) }

    var right3: float3 { float3(sin(yaw), -cos(yaw), 0) }

    /// Velocidad en planta de este fotograma (cinemática o del deslizamiento).
    var planarVel: float2 {
        if dyn { return dynVel }
        let f = fwd * speed
        return float2(f.x, f.y) + (mode == .parked ? knock : float2(0, 0))
    }

    /// Empieza el deslizamiento físico con la velocidad actual.
    func beginDynamic(vel: float2, yawRate w: Float) {
        if !dyn { dynTime = 0 }
        dyn = true; dynVel = vel; yawRate = w; dynCalm = 0
        knock = .zero; knockSpin = 0
    }

    /// Un paso del deslizamiento: fricción de neumáticos (μ g) y freno, giro amortiguado, muros y suelo de la colisión real.
    func stepDynamic(collision: CollisionWorld, dt: Float) {
        guard dyn else { return }
        dynTime += dt
        let g: Float = 9.81
        let f2 = float2(cos(yaw), sin(yaw)), r2 = float2(sin(yaw), -cos(yaw))
        var lon = simd_dot(dynVel, f2), lat = simd_dot(dynVel, r2)
        // Lateral: neumáticos deslizando (μ ≈ 0,9) [I]; longitudinal: rodadura y freno (0,25 de freno en los destruidos [D])
        let muLat: Float = 0.9
        let brake: Float = damage.destroyed || immobilized > 0 ? 0.25 * 9 : (kind == .traffic ? 6 : 3)
        lat -= (lat > 0 ? 1 : -1) * min(abs(lat), muLat * g * dt)
        lon -= (lon > 0 ? 1 : -1) * min(abs(lon), (brake + 0.4) * dt)
        dynVel = f2 * lon + r2 * lat
        // Giro: par de los neumáticos al deslizar de lado frena el giro [I]
        yawRate *= powf(0.25, dt)
        yawRate -= (yawRate > 0 ? 1 : -1) * min(abs(yawRate), 1.2 * dt)
        let step = float3(dynVel.x, dynVel.y, 0) * dt
        var to = pos + step
        // Muros: esquinas de la caja contra los muros de la colisión (empuje y rebote con WALL_ELASTICITY ≈ 0,15) [I]
        let walls = collision.walls(near: SIMD2(to.x, to.y), radius: radius + 1)
        if !walls.isEmpty {
            for (sx, sy) in [(1, 1), (1, -1), (-1, 1), (-1, -1)] as [(Float, Float)] {
                let c = to + float3(cos(yaw), sin(yaw), 0) * (model.halfLength * sx) + right3 * (model.halfWidth * sy)
                let c2 = SIMD2(c.x, c.y), o2 = SIMD2(to.x, to.y)
                for w in walls where w.zMax > pos.z + 0.3 && w.zMin < pos.z + 1.5 {
                    let s = w.b - w.a, rr = c2 - o2
                    let den = rr.x * s.y - rr.y * s.x
                    if abs(den) < 1e-9 { continue }
                    let qq = w.a - o2
                    let t = (qq.x * s.y - qq.y * s.x) / den, u = (qq.x * rr.y - qq.y * rr.x) / den
                    guard t >= 0, t <= 1, u >= 0, u <= 1 else { continue }
                    var n = simd_normalize(SIMD2(-s.y, s.x))
                    if simd_dot(o2 - w.a, n) < 0 { n = -n }
                    let depth = -simd_dot(c2 - w.a, n)
                    guard depth > 0 else { continue }
                    to += float3(n.x, n.y, 0) * (depth + 0.01)
                    let vn = simd_dot(dynVel, n)
                    if vn < 0 { dynVel -= n * vn * 1.15; yawRate += (sx * sy) * vn * 0.15 }
                }
            }
        }
        pos = to
        yaw += yawRate * dt
        speed = lon
        spin += lon * dt / model.wheelRadius
        braking = true
        if let gnd = collision.ground(x: pos.x, y: pos.y, z: pos.z + 1.2, step: 1.5) { pos.z = gnd.z; groundOK = true }
        // Fin del deslizamiento: casi parado un rato [I]
        if simd_length(dynVel) < 0.6 && abs(yawRate) < 0.25 { dynCalm += dt } else { dynCalm = 0 }
        if dynCalm > 0.4 || dynTime > 12 { dyn = false; dynVel = .zero; yawRate = 0; speed = 0 }
    }

    /// Policía: paso de choque antes de su conducción normal. Devuelve true si este fotograma ya lo ha movido el choque
    /// (deslizando, destruida o inmovilizada) y no debe conducir.
    func copCrashStep(world w: AIWorld, police: PoliceManager, dt: Float) -> Bool {
        damage.update(dt: dt, specs: crashSpecs?.damage)
        if immobilized > 0 { immobilized -= dt }
        if damage.destroyed || immobilized > 0 {
            lights = false
            if dyn { stepDynamic(collision: w.collision, dt: dt) }
            else { speed = max(0, speed - 9 * dt); braking = true }
            mode = .parked
            return true
        }
        if dyn {
            stepDynamic(collision: w.collision, dt: dt)
            if !dyn && copRole != .roadblock { police.relane(self); laneLock = 1.5 }   // AIActionGetUnstuck [D]
            return true
        }
        return false
    }
}
