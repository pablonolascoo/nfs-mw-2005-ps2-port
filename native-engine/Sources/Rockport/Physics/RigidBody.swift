// Cuerpo rígido del coche [D: Physics/Behaviors/RigidBody.cpp DoIntegration, Resolve*, OnBeginFrame, Damp;
// Dynamics/Inertia.h Box; Sim/Common/Util.cpp Util_GenerateCarTensor]. Espacio del juego (x derecha, y arriba, z adelante).
// Euler semiimplícito: v += F/m·dt; p += v·dt; ω += I⁻¹_mundo·τ·dt; giro con cuaternión; el giro es alrededor del CG.
import simd

final class RigidBody {
    var position = V3(0, 0, 0)         // origen del cuerpo (centro de la caja `dimension`)
    var orientation = simd_quatf(angle: 0, axis: V3(0, 1, 0))
    var linearVel = V3(0, 0, 0)
    var angularVel = V3(0, 0, 0)
    var force = V3(0, 0, 0)
    var torque = V3(0, 0, 0)
    let mass: Float
    /// Tensor de inercia local (diagonal) [D: Box(m, 2w, 2h, 2l) × TENSOR_SCALE].
    let inertia: V3
    /// Medias dimensiones (x ancho, y alto, z largo) [I: caja del modelo; PVehicle.cpp no está decompilado].
    let dimension: V3
    /// Centro de gravedad local (Chassis::SetCOG lo cambia cada paso).
    var cog = V3(0, 0, 0)
    var hadCollision = false

    init(mass: Float, dimension: V3, tensorScale: V3) {
        self.mass = mass; self.dimension = dimension
        let w = 2 * dimension.x, h = 2 * dimension.y, l = 2 * dimension.z
        inertia = V3((h * h + l * l) / 12, (w * w + l * l) / 12, (w * w + h * h) / 12) * mass * tensorScale
    }

    var right: V3 { orientation.act(V3(1, 0, 0)) }
    var up: V3 { orientation.act(V3(0, 1, 0)) }
    var forward: V3 { orientation.act(V3(0, 0, 1)) }
    /// UMath::Rotate(local, matrix): local → mundo (sin traslación).
    func rotate(_ v: V3) -> V3 { orientation.act(v) }
    func toLocal(_ v: V3) -> V3 { orientation.inverse.act(v) }
    var worldCog: V3 { rotate(cog) }

    /// I⁻¹ en mundo aplicado a un vector [D: Inertia::Tensor::GetInverseWorldTensor].
    func invWorldTensor(_ v: V3) -> V3 {
        let l = toLocal(v)
        return rotate(V3(inertia.x > PM.uEpsilon ? l.x / inertia.x : l.x, inertia.y > PM.uEpsilon ? l.y / inertia.y : l.y,
                         inertia.z > PM.uEpsilon ? l.z / inertia.z : l.z))
    }
    func pointVelocity(_ worldPoint: V3) -> V3 { linearVel + simd_cross(angularVel, worldPoint - (position + worldCog)) }

    func resolve(force f: V3, torque t: V3) { force += f; torque += t }
    func resolveForce(_ f: V3) { force += f }
    func resolveTorque(_ t: V3) { torque += t }
    /// Fuerza en un punto del mundo: suma también el par respecto al CG [D: ResolveForce(force, p)].
    func resolveForce(_ f: V3, at p: V3) {
        let r = p - (worldCog + position)
        torque += simd_cross(r, f); force += f
    }

    func damp(_ amount: Float) {
        let s = 1 - amount
        linearVel *= s; angularVel *= s; force *= s; torque *= s
    }

    func integrate(_ dT: Float) {
        let cg0 = rotate(cog)
        linearVel += force * (dT / mass)
        position += linearVel * dT
        angularVel += invWorldTensor(torque * dT)
        linearVel = simd_clamp(linearVel, V3(repeating: -300), V3(repeating: 300))
        angularVel = simd_clamp(angularVel, V3(repeating: -30), V3(repeating: 30))
        let w = simd_length(angularVel)
        if w > 0 { orientation = simd_normalize(simd_quatf(angle: w * dT, axis: angularVel / w) * orientation) }
        let cg1 = rotate(cog)
        position += cg0 - cg1
        force = .zero; torque = .zero
    }
}
