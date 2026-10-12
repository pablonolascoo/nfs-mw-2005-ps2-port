// Coche del jugador: modelo del juego (cars/<NOMBRE>.glb) con una pieza por ranura, ruedas y frenos montados como el juego
// (cars.json), pintura sobre los materiales con role "pintura", y una conducción arcade sobre la colisión real.
// Igual que viewer/src/drive.ts (applyCarConfig, mountWheels, paintCar, carHolder). No es la física del juego.
import Foundation
import Metal
import simd

/// Tuneo del coche. Por defecto, de serie (kit 0, capó del kit, sin alerón de tuneo).
/// Las llantas, alerones y tomas de techo de tuneo viven en packs aparte (WHEELS, SPOILER, ROOF): aún no se montan aquí.
struct CarConfig {
    var kit = 0
    var hood: Int? = nil
    var spoiler: String? = nil
}

final class Car {
    let mesh: GPUMesh
    /// Transformación local que centra el modelo, lo apoya en z = 0 y pone el morro hacia +X.
    let local: float4x4
    /// Por rueda: eje (espacio del modelo), caída (rad, sobre X) y si es delantera.
    let wheelAxles: [float3]
    let wheelCamber: [Float]
    let wheelFront: [Bool]
    let wheelRadius: Float
    let frontSign: Float
    let halfLength: Float, halfWidth: Float
    /// Piezas: 0 = carrocería, 1…4 = ruedas, 5…8 = frenos (mismo orden que TireOffsets).
    static let partCount = 9

    // Estado de conducción
    var position = float3(0, 0, 0)
    var yaw: Float = 0
    var speed: Float = 0      // m/s
    var vz: Float = 0
    var grounded = false
    var pitch: Float = 0, roll: Float = 0
    var steer: Float = 0
    var spin: Float = 0

    /// Qué primitivas se ven con esta configuración: una pieza por ranura, como RideInfo + CarRenderInfo
    /// [D: CarInfo.cpp SetStockParts, CarRender.cpp UpdateCarParts]. Copia de applyCarConfig (viewer/src/drive.ts).
    static func visibleParts(_ prims: [GLBPrimitive], _ cfg: CarConfig) -> [Bool] {
        var kitsBySlot: [String: Set<Int>] = [:]
        var hasStyleHood = false
        var normal = Set<String>()   // ranura|kit con pieza normal: gana al panel DAMAGE0 (intacto) de la misma ranura
        for p in prims {
            guard let q = p.piece else { continue }
            if let k = q.kit { kitsBySlot[q.slot, default: []].insert(k) }
            if q.kind == "capo", let h = cfg.hood, q.style == h { hasStyleHood = true }
            if let k = q.kit, q.variant != "DAMAGE0", q.kind != "dano" { normal.insert("\(q.slot)|\(k)") }
        }
        func kitFor(_ slot: String) -> Int { kitsBySlot[slot]?.contains(cfg.kit) == true ? cfg.kit : 0 }
        return prims.map { p in
            guard let q = p.piece else { return true }
            var v = q.stock
            if q.kind == "dano" || q.kind == "calcomania" { v = false }
            else if let k = q.kit { v = k == kitFor(q.slot) }
            else if q.kind == "capo" { v = hasStyleHood && q.style == cfg.hood }
            if q.variant == "DAMAGE0", let k = q.kit, normal.contains("\(q.slot)|\(k)") { v = false }
            if q.slot == "HOOD" && q.kind != "capo" && hasStyleHood { v = false }
            if q.slot == "UNIVERSAL_SPOILER_BASE" { v = cfg.spoiler != nil && q.kit == kitFor(q.slot) }
            if q.slot == "SPOILER" && q.kind != "aleron" && cfg.spoiler != nil { v = false }
            return v
        }
    }

    /// Copia una primitiva aplicando `m` a posiciones y normales (normal con la inversa traspuesta: hay escalas y espejos).
    static func transformed(_ p: GLBPrimitive, _ m: float4x4) -> GLBPrimitive {
        var q = p
        let n3 = simd_float3x3(float3(m.columns.0.x, m.columns.0.y, m.columns.0.z), float3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                               float3(m.columns.2.x, m.columns.2.y, m.columns.2.z)).inverse.transpose
        for k in q.vertices.indices {
            var v = q.vertices[k]
            let w = m * float4(v.px, v.py, v.pz, 1)
            v.px = w.x; v.py = w.y; v.pz = w.z
            func s(_ b: UInt32) -> Float { Float(Int8(bitPattern: UInt8(b & 0xff))) / 127 }
            let n = n3 * float3(s(v.normal), s(v.normal >> 8), s(v.normal >> 16))
            let l = simd_length(n)
            v.normal = packNormal(l > 0 ? n / l : float3(0, 0, 1))
            q.vertices[k] = v
        }
        return q
    }

    init?(device: MTLDevice, data: GameData, textures: TextureCache, name: String, paint: float3, config: CarConfig = CarConfig()) {
        let url = data.url("cars/\(name).glb")
        guard let file = try? GLB.load(url) else { fputs("coche: no se pudo leer \(url.path)\n", stderr); return nil }
        let attr = data.carAttribs(name)
        let vis = Car.visibleParts(file.primitives, config)
        let shown = file.primitives.indices.filter { vis[$0] }.map { file.primitives[$0] }

        // Modelo de rueda = pieza FRONT_TIRE (detrás, REAR_TIRE si existe); frenos FRONT_BRAKE / REAR_BRAKE [D: CarRender.cpp 1855-1999].
        func node(_ suffix: String) -> String? {
            shown.first { $0.piece != nil && $0.nodeName.range(of: "_\(suffix)(_[A-E])?$", options: .regularExpression) != nil }?.nodeName
        }
        let tireF = node("FRONT_TIRE"), tireR = node("REAR_TIRE") ?? tireF
        let brakeF = node("FRONT_BRAKE"), brakeR = node("REAR_BRAKE") ?? brakeF
        let mounted = attr?.tires != nil && tireF != nil
        let special = Set([tireF, tireR, brakeF, brakeR].compactMap { $0 })

        var prims: [GLBPrimitive] = []
        var parts: [Int] = []
        var box = AABB.empty
        func add(_ p: GLBPrimitive, part: Int, rest: float4x4 = .identity) {
            prims.append(p); parts.append(part)
            for v in p.vertices { let w = rest * float4(v.px, v.py, v.pz, 1); box.add(float3(w.x, w.y, w.z)) }
        }
        for p in shown where !(mounted && special.contains(p.nodeName)) { add(p, part: 0) }

        var axles: [float3] = [], cambers: [Float] = [], front: [Bool] = []
        var radius: Float = 0.33
        if mounted, let attr, let tires = attr.tires {
            let kit = config.kit
            func primsOf(_ n: String?) -> [GLBPrimitive] { n.map { n in shown.filter { $0.nodeName == n } } ?? [] }
            func boxOf(_ ps: [GLBPrimitive]) -> AABB { var b = AABB.empty; for p in ps { for v in p.vertices { b.add(float3(v.px, v.py, v.pz)) } }; return b }
            for (i, t) in tires.prefix(4).enumerated() where t.count >= 4 {
                let isFront = i <= 1, left = i == 0 || i == 3
                let wheel = primsOf(isFront ? tireF : tireR)
                let wb = boxOf(wheel)
                // Cara de la llanta en y = 0 del modelo; tapa TIRE_BACK en y = ancho [V: BMW M3 GTR].
                let W = wb.size.y, R = wb.size.x / 2
                let ksRaw = attr.kitWidthScale.flatMap { kit < $0.count ? $0[kit] : nil }.flatMap { $0.count > (isFront ? 0 : 1) ? $0[isFront ? 0 : 1] : nil } ?? 1
                let ks = ksRaw != 0 ? ksRaw : 1
                let desired = (attr.skidWidth.flatMap { i < $0.count ? $0[i] : nil } ?? 0) * ks
                let sw: Float = desired > 0 && W > 0 ? desired / W : 1
                let sr: Float = t[3] > 0 && R > 0 ? t[3] / R : 1
                let pivotY = W * sw * 0.5
                // Eje: la cara de la llanta queda en |TireOffsets.y| (+ KitWheelOffset en mm, hacia fuera).
                var yoff = -t[1]
                let kOff = ((isFront ? attr.kitOffsetFront : attr.kitOffsetRear).flatMap { kit < $0.count ? $0[kit] : nil } ?? 0) * 0.001
                yoff += yoff <= 0 ? -kOff : kOff
                let axleY = yoff < 0 ? -(yoff + pivotY) : pivotY - yoff
                // Caída: Camber × 7° sobre X (+ en las izquierdas), y la rueda baja Camber × 0,03; FECompressions sube el eje.
                let camber = attr.camber.flatMap { $0.count > (isFront ? 0 : 1) ? $0[isFront ? 0 : 1] : nil } ?? 0
                let ang = camber * 7 * .pi / 180 * (left ? 1 : -1)
                let fe = attr.feCompression.flatMap { $0.count > (isFront ? 0 : 1) ? $0[isFront ? 0 : 1] : nil } ?? 0
                let axle = float3(t[0], axleY, t[2] + fe - camber * 0.03)
                let C = float4x4(translation: axle) * float4x4(rotationX: ang)
                // Lado izquierdo: giro de 180° en Z, o espejo en Y si WheelSpokeCount & 0x80.
                let mirrorLeft = ((attr.spokes ?? 0) & 0x80) != 0
                let F: float4x4 = left ? (mirrorLeft ? float4x4(scale: float3(1, -1, 1)) : float4x4(rotationZ: .pi)) : .identity
                let P = float4x4(translation: float3(0, -pivotY, 0)) * float4x4(scale: float3(sr, sw, sr))
                for p in wheel { add(Car.transformed(p, F * P), part: 1 + i, rest: C) }
                // Freno: y del marcador FRONT_BRAKE/REAR_BRAKE de la rueda, sin escala de radio, en espejo a la izquierda.
                let brake = primsOf(isFront ? brakeF : brakeR)
                if !brake.isEmpty {
                    let my = wheel.first?.markers[isFront ? "FRONT_BRAKE" : "REAR_BRAKE"]?.columns.3.y ?? 0
                    let Pb = float4x4(translation: float3(0, my * sw - pivotY, 0))
                    let Fb: float4x4 = left ? float4x4(scale: float3(1, -1, 1)) : .identity
                    for p in brake { add(Car.transformed(p, Fb * Pb), part: 5 + i, rest: C) }
                }
                axles.append(axle); cambers.append(ang); front.append(isFront)
                radius = t[3] > 0 ? t[3] : R * sr
            }
        }
        wheelAxles = axles
        wheelCamber = cambers
        wheelRadius = max(0.2, radius)

        // Morro: lado de los faros (piezas visibles)
        var head = AABB.empty
        for p in shown where p.nodeName.uppercased().contains("HEADLIGHT") { for v in p.vertices { head.add(float3(v.px, v.py, v.pz)) } }
        frontSign = head.isEmpty || head.center.x >= box.center.x ? 1 : -1
        let fs = frontSign
        // TireOffsets: 0-1 delanteras (x > 0 en el modelo); con el morro hacia -X serían las otras.
        wheelFront = zip(front, axles).map { fs > 0 ? $0.0 : $0.1.x < 0 }
        let c = box.center
        local = float4x4(rotationZ: frontSign > 0 ? 0 : .pi) * float4x4(translation: float3(-c.x, -c.y, -box.min.z))
        halfLength = max(box.size.x, box.size.y) / 2
        halfWidth = min(box.size.x, box.size.y) / 2

        // GPUMesh.build agrupa por (pieza, material): la pieza sale de un índice paralelo
        let tagged = zip(prims, parts).map { p, part -> GLBPrimitive in var q = p; q.nodeName = "\(part)|" + p.nodeName; return q }
        guard let m = GPUMesh.build(device: device, file: file, textures: textures, keyPrefix: url.path, prims: tagged,
                                    partOf: { Int($0.nodeName.split(separator: "|").first ?? "0") ?? 0 }) else { return nil }
        // Pintura del jugador sobre <COCHE>_SKIN1 (role "pintura"). Las tarjetas de llanta ya miran bien: se dibujan.
        for i in m.draws.indices where m.draws[i].role == "pintura" { m.draws[i].color = float4(srgbToLinear(paint), 1) }
        mesh = m
        if ProcessInfo.processInfo.environment["ROCKPORT_DEBUG_CAR"] != nil {   // depuración: tramos de dibujo del coche
            for d in m.draws { print("tramo pieza \(d.part) \(d.name) \(d.kind) tex \(d.texture.map { "\($0.width)x\($0.height)" } ?? "—") tri \(d.indexCount / 3)") }
        }
    }

    /// Matrices de las piezas (0 = carrocería, 1…4 = ruedas, 5…8 = frenos) para este fotograma.
    /// Rueda: eje · dirección (Z) · caída (X) · giro (Y). El freno no gira con la rueda.
    var partMatrices: [float4x4] {
        let world = float4x4(translation: position) * float4x4(rotationZ: yaw) * float4x4(rotationX: roll) * float4x4(rotationY: -pitch) * local
        var out = [float4x4](repeating: world, count: Car.partCount)
        for (i, a) in wheelAxles.enumerated() {
            let st = wheelFront[i] ? steer * 0.45 * frontSign : 0
            let hub = world * float4x4(translation: a) * float4x4(rotationZ: st) * float4x4(rotationX: wheelCamber[i])
            out[1 + i] = hub * float4x4(rotationY: spin * frontSign)
            out[5 + i] = hub
        }
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
