// Modelos de los coches de la IA (tráfico y policía): cars/<MODELO>.glb montados como el juego —una pieza por ranura,
// la rueda FRONT_TIRE colocada cuatro veces con TireOffsets de cars.json y los frenos en su marcador— igual que
// Car.swift / viewer/src/drive.ts (applyCarConfig, mountWheels). Copia independiente para no depender del coche del jugador.
// Tráfico y policía llevan su librea real (<MODELO>_SKIN1 es una textura de verdad en el disco [V]); no se repintan.
// Los coches de policía guardan la posición de sus luces (marcadores COPLIGHTRED / COPLIGHTBLUE / COPLIGHTWHITE del BODY,
// bStringHash 1e4150b4 / e662c161 / b4348dba [V]) para los destellos de la barra [D: CarRender.cpp 2223-2238].
import Foundation
import Metal
import simd

final class AIModel {
    enum FlareKind: Int { case red = 0, blue = 1, white = 2 }
    let name: String
    let mesh: GPUMesh
    let local: float4x4
    let wheelAxles: [float3]
    let wheelCamber: [Float]
    let wheelFront: [Bool]
    let frontSign: Float
    let wheelRadius: Float
    let halfLength: Float, halfWidth: Float, height: Float
    /// Destellos de la barra de luces (posición en espacio del coche: X adelante, Y izquierda, Z arriba desde el suelo).
    let flares: [(pos: float3, kind: FlareKind)]
    static let partCount = 9

    init(name: String, mesh: GPUMesh, local: float4x4, axles: [float3], camber: [Float], front: [Bool], frontSign: Float,
         radius: Float, halfLength: Float, halfWidth: Float, height: Float, flares: [(pos: float3, kind: FlareKind)]) {
        self.name = name; self.mesh = mesh; self.local = local; wheelAxles = axles; wheelCamber = camber; wheelFront = front
        self.frontSign = frontSign; wheelRadius = radius; self.halfLength = halfLength; self.halfWidth = halfWidth; self.height = height
        self.flares = flares
    }

    /// Matrices de las 9 piezas (0 carrocería, 1…4 ruedas, 5…8 frenos) para una pose.
    func partMatrices(position: float3, yaw: Float, pitch: Float, roll: Float, steer: Float, spin: Float) -> [float4x4] {
        let world = float4x4(translation: position) * float4x4(rotationZ: yaw) * float4x4(rotationX: roll) * float4x4(rotationY: -pitch) * local
        var out = [float4x4](repeating: world, count: AIModel.partCount)
        for (i, a) in wheelAxles.enumerated() where i < 4 {
            let st = wheelFront[i] ? steer * 0.45 * frontSign : 0
            let hub = world * float4x4(translation: a) * float4x4(rotationZ: st) * float4x4(rotationX: wheelCamber[i])
            out[1 + i] = hub * float4x4(rotationY: spin * frontSign)
            out[5 + i] = hub
        }
        return out
    }

    // MARK: Montaje

    /// Una pieza por ranura [D: CarInfo.cpp SetStockParts, CarRender.cpp]. Tráfico y policía: kit 0 de serie;
    /// un panel DAMAGE0 (intacto) se ve si su ranura no tiene pieza normal; fuera daños y zonas de vinilo.
    static func visible(_ prims: [GLBPrimitive]) -> [Bool] {
        var normal = Set<String>()
        for p in prims { if let q = p.piece, let k = q.kit, q.variant != "DAMAGE0", q.kind != "dano" { normal.insert("\(q.slot)|\(k)") } }
        return prims.map { p in
            guard let q = p.piece else { return true }
            var v = q.stock
            if q.kind == "dano" || q.kind == "calcomania" { v = false }
            else if let k = q.kit { v = k == 0 }
            else if q.kind == "capo" { v = false }
            if q.variant == "DAMAGE0", let k = q.kit, normal.contains("\(q.slot)|\(k)") { v = false }
            if q.slot == "UNIVERSAL_SPOILER_BASE" { v = false }
            return v
        }
    }

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

    /// Marcadores de luz de policía leídos del JSON del GLB (el lector común guarda un marcador por nombre; aquí hacen falta todos).
    static func copLightMarkers(_ url: URL) -> [(float3, FlareKind)] {
        guard let d = try? Data(contentsOf: url), d.count > 20 else { return [] }
        let jl = Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self) })
        guard d.count >= 20 + jl, let j = try? JSONSerialization.jsonObject(with: d.subdata(in: 20..<(20 + jl))) as? [String: Any] else { return [] }
        var out: [(float3, FlareKind)] = []
        let kinds: [String: FlareKind] = ["1e4150b4": .red, "e662c161": .blue, "b4348dba": .white, "COPLIGHTRED": .red, "COPLIGHTBLUE": .blue, "COPLIGHTWHITE": .white]
        for n in j["nodes"] as? [[String: Any]] ?? [] {
            guard let ex = n["extras"] as? [String: Any], let ms = ex["marcadores"] as? [[String: Any]] else { continue }
            for m in ms {
                guard let nm = m["nombre"] as? String, let k = kinds[nm], let f = m["matriz"] as? [NSNumber], f.count == 16 else { continue }
                out.append((float3(f[12].floatValue, f[13].floatValue, f[14].floatValue), k))
            }
        }
        return out
    }

    static func build(device: MTLDevice, data: GameData, textures: TextureCache, name: String) -> AIModel? {
        let url = data.url("cars/\(name).glb")
        guard let file = try? GLB.load(url) else { fputs("IA: no se pudo leer \(url.path)\n", stderr); return nil }
        let attr = data.carAttribs(name)
        let vis = visible(file.primitives)
        let shown = file.primitives.indices.filter { vis[$0] }.map { file.primitives[$0] }
        func node(_ suffix: String) -> String? {
            shown.first { $0.piece != nil && $0.nodeName.range(of: "_\(suffix)(_[A-E])?$", options: .regularExpression) != nil }?.nodeName
        }
        let tireF = node("FRONT_TIRE"), tireR = node("REAR_TIRE") ?? tireF
        let brakeF = node("FRONT_BRAKE"), brakeR = node("REAR_BRAKE") ?? brakeF
        let mounted = attr?.tires != nil && tireF != nil
        let special = Set([tireF, tireR, brakeF, brakeR].compactMap { $0 })

        var prims: [GLBPrimitive] = [], parts: [Int] = []
        var box = AABB.empty
        func add(_ p: GLBPrimitive, part: Int, rest: float4x4 = .identity) {
            prims.append(p); parts.append(part)
            for v in p.vertices { let w = rest * float4(v.px, v.py, v.pz, 1); box.add(float3(w.x, w.y, w.z)) }
        }
        for p in shown where !(mounted && special.contains(p.nodeName)) { add(p, part: 0) }

        var axles: [float3] = [], cambers: [Float] = [], front: [Bool] = []
        var radius: Float = 0.33
        if mounted, let attr, let tires = attr.tires {
            func primsOf(_ n: String?) -> [GLBPrimitive] { n.map { n in shown.filter { $0.nodeName == n } } ?? [] }
            func boxOf(_ ps: [GLBPrimitive]) -> AABB { var b = AABB.empty; for p in ps { for v in p.vertices { b.add(float3(v.px, v.py, v.pz)) } }; return b }
            for (i, t) in tires.prefix(4).enumerated() where t.count >= 4 {
                let isFront = i <= 1, left = i == 0 || i == 3
                let wheel = primsOf(isFront ? tireF : tireR)
                let wb = boxOf(wheel)
                let W = wb.size.y, R = wb.size.x / 2
                let ksRaw = attr.kitWidthScale.flatMap { $0.first }.flatMap { $0.count > (isFront ? 0 : 1) ? $0[isFront ? 0 : 1] : nil } ?? 1
                let ks = ksRaw != 0 ? ksRaw : 1
                let desired = (attr.skidWidth.flatMap { i < $0.count ? $0[i] : nil } ?? 0) * ks
                let sw: Float = desired > 0 && W > 0 ? desired / W : 1
                let sr: Float = t[3] > 0 && R > 0 ? t[3] / R : 1
                let pivotY = W * sw * 0.5
                var yoff = -t[1]
                let kOff = ((isFront ? attr.kitOffsetFront : attr.kitOffsetRear).flatMap { $0.first } ?? 0) * 0.001
                yoff += yoff <= 0 ? -kOff : kOff
                let axleY = yoff < 0 ? -(yoff + pivotY) : pivotY - yoff
                let camber = attr.camber.flatMap { $0.count > (isFront ? 0 : 1) ? $0[isFront ? 0 : 1] : nil } ?? 0
                let ang = camber * 7 * .pi / 180 * (left ? 1 : -1)
                let fe = attr.feCompression.flatMap { $0.count > (isFront ? 0 : 1) ? $0[isFront ? 0 : 1] : nil } ?? 0
                let axle = float3(t[0], axleY, t[2] + fe - camber * 0.03)
                let C = float4x4(translation: axle) * float4x4(rotationX: ang)
                let mirrorLeft = ((attr.spokes ?? 0) & 0x80) != 0
                let F: float4x4 = left ? (mirrorLeft ? float4x4(scale: float3(1, -1, 1)) : float4x4(rotationZ: .pi)) : .identity
                let P = float4x4(translation: float3(0, -pivotY, 0)) * float4x4(scale: float3(sr, sw, sr))
                for p in wheel { add(transformed(p, F * P), part: 1 + i, rest: C) }
                let brake = primsOf(isFront ? brakeF : brakeR)
                if !brake.isEmpty {
                    let my = wheel.first?.markers[isFront ? "FRONT_BRAKE" : "REAR_BRAKE"]?.columns.3.y ?? 0
                    let Pb = float4x4(translation: float3(0, my * sw - pivotY, 0))
                    let Fb: float4x4 = left ? float4x4(scale: float3(1, -1, 1)) : .identity
                    for p in brake { add(transformed(p, Fb * Pb), part: 5 + i, rest: C) }
                }
                axles.append(axle); cambers.append(ang); front.append(isFront)
                radius = t[3] > 0 ? t[3] : R * sr
            }
        }
        guard !box.isEmpty else { return nil }
        var head = AABB.empty
        for p in shown where p.nodeName.uppercased().contains("HEADLIGHT") { for v in p.vertices { head.add(float3(v.px, v.py, v.pz)) } }
        let fs: Float = head.isEmpty || head.center.x >= box.center.x ? 1 : -1
        let wheelFront = zip(front, axles).map { fs > 0 ? $0.0 : $0.1.x < 0 }
        let c = box.center
        let local = float4x4(rotationZ: fs > 0 ? 0 : .pi) * float4x4(translation: float3(-c.x, -c.y, -box.min.z))
        let tagged = zip(prims, parts).map { p, part -> GLBPrimitive in var q = p; q.nodeName = "\(part)|" + p.nodeName; return q }
        guard let m = GPUMesh.build(device: device, file: file, textures: textures, keyPrefix: url.path, prims: tagged,
                                    partOf: { Int($0.nodeName.split(separator: "|").first ?? "0") ?? 0 }) else { return nil }
        // Destellos de policía en espacio del coche (misma transformación `local` que la carrocería)
        let flares = copLightMarkers(url).map { (p, k) -> (pos: float3, kind: FlareKind) in
            let w = local * float4(p, 1); return (float3(w.x, w.y, w.z), k)
        }
        return AIModel(name: name, mesh: m, local: local, axles: axles, camber: cambers, front: wheelFront, frontSign: fs,
                       radius: max(0.2, radius), halfLength: box.size.x / 2, halfWidth: box.size.y / 2, height: box.size.z, flares: flares)
    }
}

/// Carga los modelos en hilos de fondo; la IA solo usa los que ya están listos (sin tirones en el hilo principal).
final class AIModelLibrary {
    private let device: MTLDevice, data: GameData, textures: TextureCache
    private let lock = NSLock()
    private var ready: [String: AIModel] = [:]
    private var pending = Set<String>()
    private var failed = Set<String>()
    private let queue = DispatchQueue(label: "rockport.ai.models", qos: .utility, attributes: .concurrent)

    init(device: MTLDevice, data: GameData, textures: TextureCache) { self.device = device; self.data = data; self.textures = textures }

    func model(_ name: String) -> AIModel? {
        lock.lock(); defer { lock.unlock() }
        if let m = ready[name] { return m }
        if !pending.contains(name) && !failed.contains(name) { request(name) }
        return nil
    }

    /// Pide la carga (sin bloquear). Llamar con el candado tomado o desde fuera.
    private func request(_ name: String) {
        pending.insert(name)
        queue.async { [self] in
            let m = AIModel.build(device: device, data: data, textures: textures, name: name)
            lock.lock(); pending.remove(name)
            if let m { ready[name] = m } else { failed.insert(name) }
            lock.unlock()
        }
    }

    func preload(_ names: [String]) { lock.lock(); for n in Set(names) where ready[n] == nil && !pending.contains(n) && !failed.contains(n) { request(n) }; lock.unlock() }
    var allIdle: Bool { lock.lock(); defer { lock.unlock() }; return pending.isEmpty }
    var loadedCount: Int { lock.lock(); defer { lock.unlock() }; return ready.count }
}
