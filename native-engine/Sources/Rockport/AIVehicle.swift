// Un coche de la IA: seguidor cinemático propio (no usa la física del jugador).
//  - Modo carril: avanza por la Bézier del segmento a la distancia lateral de su carril (derecha del sentido de marcha),
//    cambia de segmento en los nodos con RoadNet.next (como WRoadNav::GetNextTraffic) y se apoya en la colisión real.
//  - Modo libre: persecución directa (policía a menos de 60 m del jugador, AIActionPursuitOffRoad [D]), gira hacia un
//    punto con un radio de giro limitado por la adherencia y no atraviesa los muros de colisión.
//  - Parado: accidente (tras un golpe del jugador, ACCIDENT_OVER [D]) o control de carretera.
import Foundation
import simd

final class AIVehicle {
    enum Kind { case traffic, cop }
    enum Mode { case lane, free, parked }
    enum CopRole { case patrol, pursuit, roadblock, flee }

    let id: Int
    let kind: Kind
    let model: AIModel
    let typeName: String             // colección pvehicle (traf4dseda, copmidsize…)
    var mode: Mode = .lane
    var copRole: CopRole = .patrol

    // Navegación por la red
    var seg = 0
    var forward = true               // de nodo 0 a nodo 1
    var dist: Float = 0              // metros recorridos en el segmento, en el sentido de marcha
    var lane = 0                     // n-ésimo carril desde el centro
    var lat: Float = 0               // desplazamiento lateral actual (m, + = derecha de la marcha)
    var latStart: Float = 0, latEnd: Float = 0
    var deadEnd = false

    // Pose y dinámica
    var pos = float3(0, 0, 0)
    var yaw: Float = 0, pitch: Float = 0, roll: Float = 0
    var speed: Float = 0             // m/s
    var desired: Float = 0
    var cruise: Float = 15           // velocidad de crucero del tramo (calle o autopista)
    var steer: Float = 0, spin: Float = 0
    var braking = false
    var lights = false               // barra de luces (policía)
    var crashed = false
    var knock = float2(0, 0)         // empujón tras un golpe (m/s), se apaga solo
    var knockSpin: Float = 0

    // Gestión
    var offscreenTime: Float = 0
    var age: Float = 0
    var lastSeenCheck: Float = 0
    var target = float3(0, 0, 0)     // modo libre: punto al que va
    var groundOK = true
    var blockedTime: Float = 0       // modo libre: tiempo contra un muro o sin avanzar
    var laneLock: Float = 0
    var directOK = false             // camino directo al jugador sin muros (se mira cada 0,25 s)          // tras desatascarse, segundos sin volver al modo libre
    var lastLat: Float = 0

    init(id: Int, kind: Kind, model: AIModel, typeName: String) { self.id = id; self.kind = kind; self.model = model; self.typeName = typeName }

    var fwd: float3 { float3(cos(yaw), sin(yaw), 0) }
    var radius: Float { max(model.halfLength, model.halfWidth) }

    /// Coloca el coche en un segmento y carril.
    func place(net: RoadNet, seg: Int, forward: Bool, t: Float, lane: Int, collision: CollisionWorld) {
        self.seg = seg; self.forward = forward
        let d = net.distance(seg, atT: t)
        dist = forward ? d : net.segs[seg].length - d
        self.lane = lane
        updateLaneEnds(net)
        let u = dist / net.segs[seg].length
        lat = latStart + (latEnd - latStart) * u
        lastLat = lat
        mode = .lane
        pose(net: net, collision: collision, dt: 0)
    }

    func updateLaneEnds(_ net: RoadNet) {
        let a = net.laneOffsets(seg, forward: forward, end: forward ? 0 : 1)
        let b = net.laneOffsets(seg, forward: forward, end: forward ? 1 : 0)
        let la = a.isEmpty ? (b.isEmpty ? [Float(2)] : b) : a, lb = b.isEmpty ? la : b
        lane = min(lane, max(la.count, lb.count) - 1)
        latStart = la[min(lane, la.count - 1)]
        latEnd = lb[min(lane, lb.count - 1)]
    }

    /// Punto del eje y tangente en el sentido de marcha para la distancia `d` del segmento actual.
    func axis(_ net: RoadNet, _ d: Float) -> (p: float3, t: float3) {
        let L = net.segs[seg].length
        let tt = net.t(seg, atDistance: forward ? d : L - d)
        let tan = net.tangent(seg, tt)
        return (net.point(seg, tt), forward ? tan : -tan)
    }

    /// Avanza por la red `step` metros, cambiando de segmento en los nodos.
    func advance(net: RoadNet, step: Float, cops: Bool, field: [Float]?, rng: inout SplitMix) {
        dist += step
        var guardN = 0
        while dist >= net.segs[seg].length && guardN < 8 {
            guardN += 1
            let rest = dist - net.segs[seg].length
            let node = forward ? net.segs[seg].n1 : net.segs[seg].n0
            var pick = net.next(from: seg, at: node, cops: cops, field: field, rng: &rng)
            if pick == nil && kind == .cop {
                // La policía no se queda atascada: cualquier tramo que salga del nodo (aunque sea de sentido único)
                pick = net.nodeSegs[node].filter { $0 != seg && $0 < net.count }.min { a, b in
                    (field.map { net.segs[a].length + $0[net.otherNode(a, node)] } ?? Float(a)) < (field.map { net.segs[b].length + $0[net.otherNode(b, node)] } ?? Float(b))
                }
            }
            guard let nx = pick else {
                // Sin salida: media vuelta si el tramo lo permite (el juego se para, fDeadEnd [D])
                if !net.segs[seg].has(RoadSegFlags.oneWay) { forward.toggle(); dist = rest; updateLaneEnds(net); lat = latStart }
                else { deadEnd = true; dist = net.segs[seg].length; speed = 0 }
                return
            }
            seg = nx
            forward = net.segs[nx].n0 == node
            dist = rest
            updateLaneEnds(net)
        }
    }

    /// Recalcula la pose en modo carril: eje + desplazamiento lateral, altura de la colisión real, cabeceo por el suelo.
    func pose(net: RoadNet, collision: CollisionWorld, dt: Float) {
        let L = net.segs[seg].length
        let u = max(0, min(1, dist / L))
        let want = latStart + (latEnd - latStart) * u
        // El lateral sigue al del carril sin saltos (cambio de perfil en un nodo: transición suave)
        let maxRate: Float = dt > 0 ? 2.5 * dt : 100
        lastLat = lat
        lat += max(-maxRate, min(maxRate, want - lat))
        let (p, t) = axis(net, dist)
        let right = simd_normalize(float3(t.y, -t.x, 0) + 1e-9)
        var q = p + right * lat
        let h = atan2(t.y, t.x)
        // pequeña corrección de rumbo por el cambio lateral
        let latRate = dt > 0 ? (lat - lastLat) / dt : 0
        let newYaw = h - atan2(latRate, max(speed, 2))
        if dt > 0 { steer = max(-1, min(1, angleDiff(newYaw, yaw) / max(dt, 1e-3) / 1.5)) }
        yaw = newYaw
        groundOK = false
        if let g = collision.ground(x: q.x, y: q.y, z: p.z + 0.6, step: 1.6) { q.z = g.z; groundOK = true } else { q.z = p.z }
        pos = q
        // cabeceo: pendiente de la tangente
        pitch = asin(max(-1, min(1, t.z)))
        roll = 0
    }

    /// Modo libre: gira hacia `target` con radio de giro limitado y avanza sin cruzar muros.
    func driveFree(collision: CollisionWorld, dt: Float, mu: Float) {
        let to = float2(target.x - pos.x, target.y - pos.y)
        if simd_length(to) > 0.5 {
            let want = atan2(to.y, to.x)
            let maxRate = min(2.6, mu * 9.8 / max(speed, 3))      // ω = a/v con a = μg
            let d = angleDiff(want, yaw)
            let turn = max(-maxRate * dt, min(maxRate * dt, d))
            yaw += turn
            steer = max(-1, min(1, d))
        }
        let step = fwd * speed * dt
        let to3 = pos + step
        if collision.hitsWall(from: pos, to: to3 + fwd * model.halfLength) {
            speed *= 0.5; blockedTime += dt
        } else {
            pos = to3
            blockedTime = speed < 1.5 && simd_length(to) > 8 ? blockedTime + dt : 0
        }
        if let g = collision.ground(x: pos.x, y: pos.y, z: pos.z + 1.2, step: 1.5) { pos.z = g.z; groundOK = true; pitch *= 0.9 }
        else { groundOK = false }
    }

    /// Empujón tras un choque: se desliza y gira un poco, luego se para (cinemático).
    func applyKnock(collision: CollisionWorld, dt: Float) {
        guard simd_length_squared(knock) > 0.01 || abs(knockSpin) > 0.01 else { return }
        let to = pos + float3(knock.x, knock.y, 0) * dt
        if !collision.hitsWall(from: pos, to: to) { pos = to }
        yaw += knockSpin * dt
        let k = powf(0.15, dt)
        knock *= k; knockSpin *= k
        if let g = collision.ground(x: pos.x, y: pos.y, z: pos.z + 1.2, step: 1.5) { pos.z = g.z }
    }

    var partMatrices: [float4x4] { model.partMatrices(position: pos, yaw: yaw, pitch: pitch, roll: roll, steer: steer, spin: spin) }
}

@inline(__always) func angleDiff(_ a: Float, _ b: Float) -> Float {
    var d = a - b
    while d > .pi { d -= 2 * .pi }
    while d < -.pi { d += 2 * .pi }
    return d
}

@inline(__always) func lerpf(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
@inline(__always) func rampf(_ x: Float, _ a: Float, _ b: Float) -> Float { max(0, min(1, (x - a) / (b - a))) }
