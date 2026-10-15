// Coche del jugador: modelo del juego (cars/<NOMBRE>.glb) con una pieza por ranura, ruedas y frenos montados como el juego
// (cars.json), pintura sobre los materiales con role "pintura", y la física del juego (Physics/) sobre la colisión real.
// Con un preset del juego (presets.json, CarSkin.swift) se montan exactamente sus piezas —kit, capó, alerón y toma de techo
// de los packs SPOILER*/ROOF, llantas de WHEELS— y la carrocería lleva la piel compuesta (pintura + vinilo) como CarSkin.cpp.
// Montaje igual que viewer/src/drive.ts (applyCarConfig, mountWheels, paintCar). Conducción: PVehicle (doc 13).
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

    // Física del juego (Physics/*.swift). nil si falta physics.json: entonces conduce el prototipo arcade.
    let specs: VehicleSpecs?
    private(set) var vehicle: PVehicle?
    /// Medias medidas de la caja del modelo (X largo, Y ancho, Z alto) y punto medio de los ejes (X, espacio `local`).
    let bodyHalf: float3
    let modelAxleMid: Float
    private var accumulator: Float = 0
    private var prevPos = SIMD3<Float>(0, 0, 0), prevRot = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    private var renderPos = SIMD3<Float>(0, 0, 0), renderRot = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    private var wheelSpin = [Float](repeating: 0, count: 4)
    private(set) var lastDriver = DriverInput()
    /// Cámara de persecución con las vistas camerainfo del coche (Camera/ChaseCamera.swift).
    lazy var camera = ChaseCamera(specs: specs)

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

    /// Packs comunes de tuneo ya leídos (WHEELS, SPOILER*, ROOF): se comparten entre coches.
    private static var packCache: [String: GLBFile] = [:]
    private static let packLock = NSLock()
    static func pack(_ data: GameData, _ name: String) -> GLBFile? {
        packLock.lock(); defer { packLock.unlock() }
        if let f = packCache[name] { return f }
        guard let f = try? GLB.load(data.url("cars/\(name).glb")) else { return nil }
        packCache[name] = f
        return f
    }

    /// Añade a `base` las primitivas de `other` cuyo nodo esté en `nodes`, con sus materiales e imágenes (índices desplazados).
    static func merged(_ base: GLBFile, _ other: GLBFile, nodes: Set<String>) -> GLBFile {
        var out = base
        let mo = base.materials.count, io = base.images.count
        out.images += other.images
        out.materials += other.materials.map { m in var q = m; q.image = m.image.map { $0 + io }; return q }
        for p in other.primitives where nodes.contains(p.nodeName) { var q = p; q.material += mo; out.primitives.append(q) }
        return out
    }

    /// Piezas visibles de un preset: exactamente sus sólidos del GLB del coche, sin zonas de calcomanía (vacías sin textura de
    /// calcomanía [D]) y UNIVERSAL_SPOILER_BASE solo con alerón de tuneo [D: CarRender.cpp 1894-1909].
    static func presetParts(_ prims: [GLBPrimitive], _ preset: CarPreset, car: String) -> [Bool] {
        let aftermarketSpoiler = preset.solid("SPOILER").map { $0.glb != car } ?? false
        var want = Set<String>()
        for s in preset.solids where s.glb == car {
            if s.slot.hasPrefix("DECAL_") { continue }
            if s.slot == "UNIVERSAL_SPOILER_BASE" && !aftermarketSpoiler { continue }
            want.insert(s.node)
        }
        return prims.map { $0.piece == nil || want.contains($0.nodeName) }
    }

    init?(device: MTLDevice, data: GameData, textures: TextureCache, name: String, paint: float3, config cfg: CarConfig = CarConfig(), preset: CarPreset? = nil) {
        let url = data.url("cars/\(name).glb")
        guard var file = try? GLB.load(url) else { fputs("coche: no se pudo leer \(url.path)\n", stderr); return nil }
        let attr = data.carAttribs(name)
        var config = cfg
        var keyPrefix = url.path
        var vis = Car.visibleParts(file.primitives, config)
        var packNodes: [String: [GLBPrimitive]] = [:]   // nodo de pack → primitivas (llantas, alerón, techo)
        if let preset {
            config.kit = preset.kit
            let pv = Car.presetParts(file.primitives, preset, car: name)
            // Sin carrocería (nombres que no cuadran): se queda la configuración normal.
            if file.primitives.indices.contains(where: { pv[$0] && file.primitives[$0].piece?.slot == "BODY" }) { vis = pv }
            else { fputs("coche: el preset \(preset.name) no encaja con \(name); se monta de serie\n", stderr) }
            let byPack = Dictionary(grouping: preset.solids.filter { $0.glb != name }, by: \.glb)
            for packName in byPack.keys.sorted() {
                guard let pf = Car.pack(data, packName) else { fputs("coche: falta el pack \(packName)\n", stderr); continue }
                let nodes = Set(byPack[packName]!.map(\.node))
                let before = file.primitives.count
                file = Car.merged(file, pf, nodes: nodes)
                vis += [Bool](repeating: false, count: file.primitives.count - before)
                for p in file.primitives[before...] { packNodes[p.nodeName, default: []].append(p) }
                keyPrefix += "+\(packName)"
            }
        }
        // Sólidos rotos del disco: CAYMANS_KIT00_REAR_*_WINDOW tiene vértices a 9 m del coche [V]; el juego no los dibuja
        // (el Cayman no tiene ventanillas traseras). Fuera todo lo que se salga de un coche (|y| > 3 m o z < -2 m).
        func sane(_ p: GLBPrimitive) -> Bool { p.piece == nil || !p.vertices.contains { abs($0.py) > 3 || $0.pz < -2 || abs($0.px) > 8 } }
        let shown = file.primitives.indices.filter { vis[$0] && sane(file.primitives[$0]) }.map { file.primitives[$0] }

        // Modelo de rueda = pieza FRONT_TIRE (detrás, REAR_TIRE si existe); frenos FRONT_BRAKE / REAR_BRAKE [D: CarRender.cpp 1855-1999].
        // Con preset: el sólido de FRONT_WHEEL / REAR_WHEEL (rueda de serie o llanta de tuneo de WHEELS, que es la rueda entera).
        func node(_ suffix: String) -> String? {
            shown.first { $0.piece != nil && $0.nodeName.range(of: "_\(suffix)(_[A-E])?$", options: .regularExpression) != nil }?.nodeName
        }
        let presetTire = preset?.solid("FRONT_WHEEL")?.node
        let tireF = presetTire ?? node("FRONT_TIRE"), tireR = preset?.solid("REAR_WHEEL")?.node ?? (presetTire != nil ? tireF : (node("REAR_TIRE") ?? tireF))
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

        // Alerón y toma de techo de tuneo en los marcadores SPOILER / ROOF_SCOOP de la pieza BASE [D: CarRender.cpp 3262-3316].
        if let preset {
            let baseMarkers = file.primitives.first { $0.piece?.slot == "BASE" }?.markers ?? [:]
            for (slot, marker) in [("SPOILER", "SPOILER"), ("ROOF", "ROOF_SCOOP")] {
                guard let s = preset.solid(slot), s.glb != name, let ps = packNodes[s.node] else { continue }
                guard let m = baseMarkers[marker] else { fputs("coche: \(name) sin marcador \(marker)\n", stderr); continue }
                for p in ps { add(Car.transformed(p, m), part: 0) }
            }
        }

        var axles: [float3] = [], cambers: [Float] = [], front: [Bool] = []
        var radius: Float = 0.33
        if mounted, let attr, let tires = attr.tires {
            let kit = config.kit
            func primsOf(_ n: String?) -> [GLBPrimitive] { n.map { n in packNodes[n] ?? shown.filter { $0.nodeName == n } } ?? [] }
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
        bodyHalf = float3(box.size.x / 2, box.size.y / 2, box.size.z / 2)
        modelAxleMid = axles.isEmpty ? 0 : axles.map { fs * ($0.x - c.x) }.reduce(0, +) / Float(axles.count)
        specs = Car.physicsFile(data)?.specs(model: name)
        if specs == nil { fputs("coche: sin physics.json para \(name): conducción arcade\n", stderr) }

        // GPUMesh.build agrupa por (pieza, material): la pieza sale de un índice paralelo
        let tagged = zip(prims, parts).map { p, part -> GLBPrimitive in var q = p; q.nodeName = "\(part)|" + p.nodeName; return q }
        guard let m = GPUMesh.build(device: device, file: file, textures: textures, keyPrefix: keyPrefix, prims: tagged,
                                    partOf: { Int($0.nodeName.split(separator: "|").first ?? "0") ?? 0 }) else { return nil }
        // Pintura del jugador sobre <COCHE>_SKIN1 (role "pintura"). Las tarjetas de llanta ya miran bien: se dibujan.
        for i in m.draws.indices where m.draws[i].role == "pintura" { m.draws[i].color = float4(srgbToLinear(paint), 1) }
        if let preset { Car.dress(m, preset: preset, file: file, data: data, textures: textures) }
        mesh = m
        if ProcessInfo.processInfo.environment["ROCKPORT_DEBUG_CAR"] != nil {   // depuración: tramos de dibujo del coche
            for d in m.draws { print("tramo pieza \(d.part) \(d.name) \(d.kind) tex \(d.texture.map { "\($0.width)x\($0.height)" } ?? "—") tri \(d.indexCount / 3)") }
        }
    }

    /// Viste la malla con el preset: piel compuesta en <COCHE>_SKIN1 / SPOILER_SKIN1 / ROOF_SKIN / GLOBAL_SKIN1 (role "pintura")
    /// [D: GetUsedCarTextureInfo, ReplaceSkinHash], acabado de la pintura, llanta teñida con PAINT_RIM y tintado de cristales.
    static func dress(_ m: GPUMesh, preset: CarPreset, file: GLBFile, data: GameData, textures: TextureCache) {
        let skin = CarSkin.texture(preset, data: data, textures: textures)
        // Acabado [I]: GLOSS = esmalte, METAL = metalizado, PEARL = perlado (el PS2 usa mapas de entorno; aquí, PBR del visor).
        let finish: float2 = switch preset.paint?.finish {
        case "METAL": float2(0.6, 0.3)
        case "PEARL": float2(0.4, 0.22)
        default: float2(0.12, 0.24)
        }
        for i in m.draws.indices where m.draws[i].role == "pintura" {
            if let skin { m.draws[i].texture = skin; m.draws[i].color = float4(1, 1, 1, 1) }
            else if let p = preset.paint { m.draws[i].color = float4(srgbToLinear(p.srgb), 1) }
            m.draws[i].pbr = finish
            // Material de luz de la pintura (LIGHT_MATERIAL_NAME: METPAINTSILVER, REGPAINTBLACK, PEARL8…) [V: presets.json] → doc 20
            m.draws[i].light = preset.paint?.material
        }
        // Llanta: <LLANTA>_WHEEL teñida con PAINT_RIM según su máscara interior [D: CompositeRim]
        if preset.rimPaint != nil, let wheelTex = preset.rim?.texture {
            if let mi = file.materials.firstIndex(where: { $0.name == wheelTex }), let im = file.materials[mi].image, im < file.images.count,
               let png = file.images[im].data, let rim = CarSkin.rimTexture(preset, wheelPNG: png, data: data, textures: textures) {
                for i in m.draws.indices where m.draws[i].name == wheelTex { m.draws[i].texture = rim }
            }
        }
        // Cristales tintados: el juego cambia su material de luz (WINDSHIELD_TINT_*, LightMaterial_WindowTint) [D]; su difusa
        // ya es el color del tinte (p. ej. L2_RED: (1, 0, 0) × 0,5, alfa 0,75) [V: fx.json]. Sin fx/ (datos < 8), el tinte aproximado.
        if let t = preset.windowTint, let mat = t.material, FXData.shared(data).material(mat) != nil {
            for i in m.draws.indices where m.draws[i].name.hasPrefix("WINDOW_") && m.draws[i].name != "WINDOW_MASK" || m.draws[i].name == "REAR_DEFROSTER" {
                m.draws[i].light = mat
            }
        } else if let t = preset.windowTint, !t.name.uppercased().hasPrefix("STOCK") {
            let v = UInt32(t.rgb, radix: 16) ?? 0
            let c = srgbToLinear(float3(Float((v >> 16) & 255), Float((v >> 8) & 255), Float(v & 255)) / 255)
            let hue = c / max(c.max(), 0.001)
            for i in m.draws.indices where m.draws[i].name.hasPrefix("WINDOW_") && m.draws[i].name != "WINDOW_MASK" || m.draws[i].name == "REAR_DEFROSTER" {
                let k = t.opacity
                let rgb = simd_mix(float3(1, 1, 1), hue * 0.55, float3(repeating: k))
                m.draws[i].color = float4(m.draws[i].color.x * rgb.x, m.draws[i].color.y * rgb.y, m.draws[i].color.z * rgb.z, min(1, m.draws[i].color.w * (1 + 0.3 * k)))
            }
        }
    }

    // MARK: - Física del juego

    private static var physicsCache: (String, PhysicsFile?)?
    static func physicsFile(_ data: GameData) -> PhysicsFile? {
        if let c = physicsCache, c.0 == data.root.path { return c.1 }
        let f = PhysicsFile.load(data)
        physicsCache = (data.root.path, f)
        return f
    }

    /// Altura del brazo de rueda en reposo (media de los ejes): RIDE_HEIGHT − compresión estática.
    private var armRest: Float {
        guard let v = vehicle else { return 0 }
        return (v.susp.rideHeight(0) - v.staticCompression[0] + v.susp.rideHeight(1) - v.staticCompression[1]) * 0.5
    }
    /// Punto medio de los ejes de la física, en z local (FRONT_AXLE − WHEEL_BASE/2).
    private var physicsAxleMid: Float { specs.map { $0.chassis.FRONT_AXLE - $0.chassis.WHEEL_BASE * 0.5 } ?? 0 }

    /// Rotación del mundo del motor (columnas: adelante, izquierda, arriba) a partir de la orientación de la física.
    private static func worldRotation(_ q: simd_quatf) -> float4x4 {
        let f = PM.toWorld(q.act(V3(0, 0, 1))), l = PM.toWorld(-q.act(V3(1, 0, 0))), u = PM.toWorld(q.act(V3(0, 1, 0)))
        return float4x4(columns: (SIMD4(f, 0), SIMD4(l, 0), SIMD4(u, 0), SIMD4(0, 0, 0, 1)))
    }
    /// Matriz del suelo bajo el coche en el mundo (origen del modelo; sin `local`).
    private var bodyWorld: float4x4 {
        guard let v = vehicle else { return float4x4(translation: position) * float4x4(rotationZ: yaw) }
        let o = PM.toWorld(renderPos + renderRot.act(V3(0, -(v.rb.dimension.y + armRest), physicsAxleMid)))
        return float4x4(translation: o) * Car.worldRotation(renderRot) * float4x4(translation: float3(-modelAxleMid, 0, 0))
    }

    /// Matrices de las piezas (0 = carrocería, 1…4 = ruedas, 5…8 = frenos) para este fotograma.
    /// Rueda: eje (+ recorrido de la suspensión) · dirección (Z) · caída (X) · giro (Y). El freno no gira con la rueda.
    var partMatrices: [float4x4] {
        guard let v = vehicle else { return arcadePartMatrices }
        let world = bodyWorld * local
        var out = [float4x4](repeating: world, count: Car.partCount)
        // TireOffsets: 0 del. izq., 1 del. dcha., 2 tras. dcha., 3 tras. izq. → ruedas de la física 0 FL, 1 FR, 2 RL, 3 RR
        let map = [0, 1, 3, 2]
        for (i, a) in wheelAxles.enumerated() where i < 4 {
            let t = v.susp.tires[map[i]]
            let dz = t.compression - v.staticCompression[map[i] / 2]
            let ang: Float = map[i] < 2 ? v.susp.steerWheels[map[i]] : 0     // rad, + = derecha
            let hub = world * float4x4(translation: a + float3(0, 0, dz)) * float4x4(rotationZ: -ang * frontSign) * float4x4(rotationX: wheelCamber[i])
            out[1 + i] = hub * float4x4(rotationY: wheelSpin[map[i]] * frontSign)
            out[5 + i] = hub
        }
        return out
    }

    /// Cuadrado unidad escalado al tamaño del coche, apoyado en el suelo (para la sombra de contacto).
    var shadowMatrix: float4x4 {
        if vehicle == nil {
            return float4x4(translation: position + float3(0, 0, 0.12)) * float4x4(rotationZ: yaw) * float4x4(rotationX: roll) * float4x4(rotationY: -pitch)
                * float4x4(scale: float3(halfLength * 1.2, halfWidth * 1.5, 1))
        }
        return float4x4(translation: float3(0, 0, 0.12)) * bodyWorld * float4x4(translation: float3(modelAxleMid, 0, 0)) * float4x4(scale: float3(halfLength * 1.2, halfWidth * 1.5, 1))
    }

    var kmh: Float { abs(speed) * 3.6 }
    var forward: float3 { float3(cos(yaw), sin(yaw), 0) }
    /// Datos para el HUD y la cámara.
    var rpm: Float { vehicle?.engine.rpm ?? 0 }
    var gear: Int { vehicle?.engine.gear ?? Gear.first }
    var nosCapacity: Float { vehicle?.engine.nosCapacity ?? 0 }
    var isNOSEngaged: Bool { vehicle?.engine.isNOSEngaged ?? false }
    var lateralSlip: Float { vehicle.map { abs($0.susp.tires[2].lateralSpeed + $0.susp.tires[3].lateralSpeed) * 0.5 } ?? 0 }
    /// Velocidad del coche en el mundo del motor (m/s).
    var velocity: float3 { vehicle.map { PM.toWorld($0.rb.linearVel) } ?? forward * speed }

    /// Para la vibración, los gatillos y la luz del mando.
    var padFeedback: PadFeedback {
        var f = PadFeedback()
        guard let v = vehicle else { return f }
        f.speed = v.speed
        f.rpmRatio = v.engine.rpm / v.specs.engine.RED_LINE
        f.onLimiter = v.engine.rpm > v.specs.engine.RED_LINE - 150 && v.controls.gas > 0.5
        f.slip = v.susp.tires.reduce(0) { $0 + abs($1.slip) + abs($1.lateralSpeed) } * 0.25
        f.brakeLocked = v.susp.tires.contains { $0.brakeLocked && $0.isOnGround } && v.speed > 3
        f.nos = v.engine.isNOSEngaged
        f.impact = v.takeImpact()
        f.grounded = v.susp.numWheelsOnGround > 0
        return f
    }

    func place(_ p: float3, yaw: Float, collision: CollisionWorld, probe: Float = 50) { place(p, yaw: yaw, ground: collision, probe: probe) }

    func place(_ p: float3, yaw: Float, ground: PhysicsGround, probe: Float = 50) {
        if vehicle == nil, let s = specs {
            // Caja del cuerpo de la física = caja del modelo (x ancho, y alto, z largo) [I: PVehicle.cpp sin decompilar]
            vehicle = PVehicle(specs: s, dimension: V3(bodyHalf.y, bodyHalf.z, bodyHalf.x), ground: ground)
        }
        position = p; self.yaw = yaw; speed = 0; vz = 0
        if let v = vehicle {
            v.place(world: p, yaw: yaw, probe: probe)
            prevPos = v.rb.position; prevRot = v.rb.orientation; renderPos = prevPos; renderRot = prevRot
            accumulator = 0
            syncFromPhysics()
        } else if let g = ground.ground(x: p.x, y: p.y, z: p.z + probe, step: 0) { position.z = g.z }
    }

    /// Recoloca el coche parado donde está, mirando hacia donde mira (tecla R / botón del mando).
    func reset() {
        guard let v = vehicle else { return }
        let gp = PM.toWorld(v.rb.position)
        place(float3(gp.x, gp.y, gp.z + 2), yaw: yaw, ground: v.ground)
    }

    struct Input {
        var throttle: Float = 0, brake: Float = 0, steer: Float = 0, handbrake = false
        /// Entrada completa (mando analógico, NOS, cambios). Si está, manda sobre los campos anteriores.
        var driver: DriverInput? = nil
    }

    private func driverInput(_ input: Input) -> DriverInput {
        if let d = input.driver { return d }
        var d = DriverInput()
        d.gas = input.throttle; d.brake = input.brake
        d.steerLeft = max(input.steer, 0); d.steerRight = max(-input.steer, 0)   // Car.Input.steer: + = izquierda
        d.handBrake = input.handbrake ? 1 : 0
        return d
    }

    /// Avanza `dt` s: la física va a paso fijo de 1/60 s y la pose dibujada se interpola entre los dos últimos pasos.
    func update(dt: Float, input: Input, collision: PhysicsGround) {
        guard let v = vehicle else {
            if let c = collision as? CollisionWorld { updateArcade(dt: dt, input: input, collision: c) }
            return
        }
        let d = driverInput(input)
        lastDriver = d
        accumulator += min(dt, 0.25)
        var steps = 0
        while accumulator >= PVehicle.timeStep && steps < 15 {
            prevPos = v.rb.position; prevRot = v.rb.orientation
            v.step(d)
            for i in 0..<4 { wheelSpin[i] += v.susp.wheelAngularVelocity(i) * PVehicle.timeStep }
            accumulator -= PVehicle.timeStep; steps += 1
        }
        if steps == 15 { accumulator = 0 }
        let a = PM.clamp(accumulator / PVehicle.timeStep, 0, 1)
        renderPos = prevPos + (v.rb.position - prevPos) * a
        renderRot = simd_slerp(prevRot, v.rb.orientation, a)
        syncFromPhysics()
        // Caída fuera del mapa: volver a la última posición válida no existe aún → recolocar sobre el suelo más alto
        if PM.toWorld(v.rb.position).z < -60 { reset() }
    }

    /// Propiedades públicas de siempre (posición en el suelo, rumbo, velocidad…) desde la física.
    private func syncFromPhysics() {
        guard let v = vehicle else { return }
        let f = PM.toWorld(renderRot.act(V3(0, 0, 1)))
        yaw = atan2(f.y, f.x)
        pitch = asin(PM.clamp(f.z, -1, 1))
        let l = PM.toWorld(-renderRot.act(V3(1, 0, 0)))
        roll = asin(PM.clamp(l.z, -1, 1))
        let b = bodyWorld * float4x4(translation: float3(modelAxleMid, 0, 0))
        position = float3(b.columns.3.x, b.columns.3.y, b.columns.3.z)
        speed = v.forwardSpeed
        vz = PM.toWorld(v.rb.linearVel).z
        grounded = v.susp.numWheelsOnGround > 0
        steer = (v.susp.steerWheels[0] + v.susp.steerWheels[1]) * 0.5
        spin = wheelSpin[2]
    }

    // MARK: - Prototipo arcade (solo si falta physics.json). Igual que viewer/src/drive.ts.

    private var arcadePartMatrices: [float4x4] {
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


    /// Paso de conducción arcade (valores de prueba del visor: 0-100 en ~5 s, 270 km/h de punta).
    private func updateArcade(dt: Float, input: Input, collision: CollisionWorld) {
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
