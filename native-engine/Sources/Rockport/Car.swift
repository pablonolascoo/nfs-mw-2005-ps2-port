// Coche del jugador: modelo del juego (cars/<NOMBRE>.glb), cuatro ruedas montadas con TireOffsets (cars.json),
// pintura sobre los materiales con role "pintura", y una conducción arcade sobre la colisión real.
// Igual que viewer/src/drive.ts (mountWheels, paintCar, hideAftermarketRimCards, carHolder). No es la física del juego.
import Foundation
import Metal
import simd

final class Car {
    let mesh: GPUMesh
    /// Transformación local que centra el modelo, lo apoya en z = 0 y pone el morro hacia +X.
    let local: float4x4
    /// Pivote de cada rueda (espacio del modelo) y si es delantera.
    let wheelPivots: [float3]
    let wheelFront: [Bool]
    let wheelRadius: Float
    let frontSign: Float
    let halfLength: Float, halfWidth: Float

    // Estado de conducción
    var position = float3(0, 0, 0)
    var yaw: Float = 0
    var speed: Float = 0      // m/s
    var vz: Float = 0
    var grounded = false
    var pitch: Float = 0, roll: Float = 0
    var steer: Float = 0
    var spin: Float = 0

    init?(device: MTLDevice, data: GameData, textures: TextureCache, name: String, paint: float3) {
        let url = data.url("cars/\(name).glb")
        guard let file = try? GLB.load(url) else { fputs("coche: no se pudo leer \(url.path)\n", stderr); return nil }
        let tires = data.cars[name.lowercased()]?.tires ?? data.cars[name]?.tires

        // Pieza de rueda: la primera malla *_TIRE_<letra> (el modelo trae una sola rueda)
        let isTire: (GLBPrimitive) -> Bool = { $0.nodeName.range(of: "_TIRE_[A-Z]$", options: [.regularExpression, .caseInsensitive]) != nil }
        let tireNode = file.primitives.first(where: isTire)?.nodeName
        var tireBox = AABB.empty
        for p in file.primitives where p.nodeName == tireNode { for v in p.vertices { tireBox.add(float3(v.px, v.py, v.pz)) } }

        var prims: [GLBPrimitive] = []
        var parts: [Int] = []
        var pivots: [float3] = [], front: [Bool] = []
        var bodyBox = AABB.empty
        for p in file.primitives where !(tireNode != nil && tires != nil && p.nodeName == tireNode) {
            prims.append(p); parts.append(0)
            for v in p.vertices { bodyBox.add(float3(v.px, v.py, v.pz)) }
        }
        if let tires, tireNode != nil, !tireBox.isEmpty {
            let c = tireBox.center
            let halfW = tireBox.size.y / 2
            // CarRender.cpp [D]: cara exterior de la llanta en |y| = TireOffsets.y; la goma se extiende hacia dentro.
            for (i, t) in tires.prefix(4).enumerated() {
                let x = t[0], y = t[1], z = t[2]
                let pivot = float3(x, (y >= 0 ? 1 : -1) * (abs(y) - halfW), z == 0 ? c.z : z)
                let mirror = (y >= 0) != (c.y >= 0)
                for p in file.primitives where p.nodeName == tireNode {
                    var q = p
                    for k in q.vertices.indices {
                        var v = q.vertices[k]
                        v.px -= c.x; v.py -= c.y; v.pz -= c.z
                        if mirror {
                            v.py = -v.py
                            let ny = Int8(bitPattern: UInt8((v.normal >> 8) & 0xff))
                            v.normal = (v.normal & 0xffff00ff) | (UInt32(UInt8(bitPattern: ny == -128 ? 127 : -ny)) << 8)
                        }
                        q.vertices[k] = v
                    }
                    prims.append(q); parts.append(i + 1)
                }
                pivots.append(pivot); front.append(x > 0)
                bodyBox.add(pivot + float3(0, 0, -tireBox.size.z / 2))
                bodyBox.add(pivot + float3(0, 0, tireBox.size.z / 2))
            }
        }
        wheelPivots = pivots
        wheelRadius = max(0.2, tireBox.isEmpty ? 0.33 : tireBox.size.z / 2)

        // Morro: lado de los faros
        var head = AABB.empty
        for p in file.primitives where p.nodeName.uppercased().contains("HEADLIGHT") { for v in p.vertices { head.add(float3(v.px, v.py, v.pz)) } }
        frontSign = head.isEmpty || head.center.x >= bodyBox.center.x ? 1 : -1
        let fs = frontSign
        wheelFront = front.map { $0 == (fs > 0) }   // `front` guarda x > 0; delanteras = lado del morro
        let c = bodyBox.center
        local = float4x4(rotationZ: frontSign > 0 ? 0 : .pi) * float4x4(translation: float3(-c.x, -c.y, -bodyBox.min.z))
        halfLength = max(bodyBox.size.x, bodyBox.size.y) / 2
        halfWidth = min(bodyBox.size.x, bodyBox.size.y) / 2

        // GPUMesh.build agrupa por (pieza, material): la pieza sale de un índice paralelo
        let tagged = zip(prims, parts).map { p, part -> GLBPrimitive in var q = p; q.nodeName = "\(part)|" + p.nodeName; return q }
        guard let m = GPUMesh.build(device: device, file: file, textures: textures, keyPrefix: url.path, prims: tagged,
                                    partOf: { Int($0.nodeName.split(separator: "|").first ?? "0") ?? 0 }) else { return nil }
        // Pintura y tarjetas de llanta de tuneo (ocultas con llantas de serie)
        for i in m.draws.indices {
            if m.draws[i].role == "pintura" { m.draws[i].color = float4(srgbToLinear(paint), 1) }
            if m.draws[i].role == "llanta" { m.draws[i].visible = false }
        }
        mesh = m
    }

    /// Matrices de las piezas (0 = carrocería, 1…4 = ruedas) para este fotograma.
    var partMatrices: [float4x4] {
        let world = float4x4(translation: position) * float4x4(rotationZ: yaw) * float4x4(rotationX: roll) * float4x4(rotationY: -pitch) * local
        var out = [world]
        for (i, p) in wheelPivots.enumerated() {
            let st = wheelFront[i] ? steer * 0.45 * frontSign : 0
            out.append(world * float4x4(translation: p) * float4x4(rotationZ: st) * float4x4(rotationY: spin * frontSign))
        }
        while out.count < 5 { out.append(world) }
        return out
    }

    /// Cuadrado unidad escalado al tamaño del coche, apoyado en el suelo (para la sombra de contacto).
    var shadowMatrix: float4x4 {
        float4x4(translation: position + float3(0, 0, 0.12)) * float4x4(rotationZ: yaw) * float4x4(rotationX: roll) * float4x4(rotationY: -pitch)
            * float4x4(scale: float3(halfLength * 1.2, halfWidth * 1.5, 1))
    }

    var kmh: Float { abs(speed) * 3.6 }
    var forward: float3 { float3(cos(yaw), sin(yaw), 0) }

    func place(_ p: float3, yaw: Float, collision: CollisionWorld) {
        position = p; self.yaw = yaw; speed = 0; vz = 0
        if let g = collision.ground(x: p.x, y: p.y, z: p.z + 50, step: 0) { position.z = g.z }
    }

    struct Input { var throttle: Float = 0, brake: Float = 0, steer: Float = 0, handbrake = false }

    /// Paso de conducción arcade (valores de prueba del visor: 0-100 en ~5 s, 270 km/h de punta).
    func update(dt: Float, input: Input, collision: CollisionWorld) {
        let MAX: Float = 75, ACC: Float = 9.5, BRAKE: Float = 26, DRAG: Float = 0.0009, ROLL: Float = 0.6
        if input.throttle > 0 { speed += ACC * input.throttle * (1 - max(0, speed) / MAX) * dt }
        if input.brake > 0 { speed -= (speed > 0.5 ? BRAKE : ACC * 0.6) * input.brake * dt }
        speed -= (speed > 0 ? 1 : speed < 0 ? -1 : 0) * (ROLL + DRAG * speed * speed) * dt
        if input.handbrake { speed *= powf(0.35, dt) }
        if abs(speed) < 0.05 && input.throttle == 0 && input.brake == 0 { speed = 0 }
        speed = max(-15, min(MAX, speed))
        steer += (input.steer - steer) * min(1, dt * 8)
        let rate = (1.9 / (1 + abs(speed) / 22)) * (input.handbrake ? 1.6 : 1)
        yaw += steer * rate * dt * (speed < 0 ? -1 : 1) * min(1, abs(speed) / 3)

        let step = speed * dt
        if abs(step) > 0 {
            let dir = forward * (step > 0 ? 1 : -1)
            let probe = position + dir * (halfLength + abs(step))
            if collision.hitsWall(from: position, to: probe) { speed *= -0.25 }
            else { position += forward * step }
        }
        spin += step / wheelRadius

        // Gravedad y suelo
        if let g = collision.ground(x: position.x, y: position.y, z: position.z), position.z - g.z < 0.6, vz <= 0 {
            position.z = g.z; vz = 0; grounded = true
        } else {
            vz -= 9.8 * dt; position.z += vz * dt; grounded = false
            if let g = collision.ground(x: position.x, y: position.y, z: position.z + 1), position.z < g.z { position.z = g.z; vz = 0 }
            if position.z < -50 { vz = 0 }   // fuera del mapa: no caer para siempre
        }
        // Inclinación según el suelo bajo las cuatro esquinas
        if grounded {
            let c = cos(yaw), s = sin(yaw), L = halfLength * 0.8, W = halfWidth * 0.8
            func h(_ dx: Float, _ dy: Float) -> Float {
                collision.ground(x: position.x + c * dx - s * dy, y: position.y + s * dx + c * dy, z: position.z)?.z ?? position.z
            }
            let fl = h(L, W), fr = h(L, -W), bl = h(-L, W), br = h(-L, -W)
            let p = atan2((fl + fr) / 2 - (bl + br) / 2, 2 * L), r = atan2((fl + bl) / 2 - (fr + br) / 2, 2 * W)
            let k = min(1, dt * 10)
            pitch += (p - pitch) * k; roll += (r - roll) * k
        }
    }
}
