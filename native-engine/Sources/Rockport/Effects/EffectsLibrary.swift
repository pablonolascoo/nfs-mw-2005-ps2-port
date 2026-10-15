// Datos de efectos del juego (paso `effects` del conversor → effects.json, doc 24) listos para el motor:
//  - `emitterdata` / `emittergroup` / `effects` / `simsurface` del VLT [V] con las curvas del juego ya resueltas
//    (EmitterDataAttribWrapper::CalculateBases [D]: colores y tamaño/ángulo interpolados por un polinomio cúbico que pasa por
//    los 4 valores en KeyPositions/3, hermite_basis de bMatrix.cpp [D]).
//  - Emisores colocados en el mundo (0x0003BC00, 1 535) y en los garajes del frontend (41) [V].
//  - Destellos del mundo (marcadores de sólido 0x0013401A, 2 242) [V] y ParameterMaps (niebla y tinte por zona) [V].
// Se lee una vez por carpeta de datos, en un hilo de fondo (3 MB de JSON, ~80 ms).
import Foundation
import simd

/// Un `emitterdata` del VLT [V: effects.json → library.emitterData; D: Generated/AttribSys/Classes/emitterdata.h].
struct EmitterDef {
    var name = ""
    var life: Float = 1, lifeVariance: Float = 0
    var numParticles: Float = 0, numParticlesVariance: Float = 0
    var speed: Float = 0, speedVariance: Float = 0
    var spreadAngle: Float = 0, spreadAsDisc = false
    var velStart = float3.zero, velDelta = float3.zero, accStart = float3.zero, accDelta = float3.zero
    var volCenter = float3.zero, volExtent = float3.zero
    var gravity: Float = 0, drag: Float = 0
    var motionInherit: Float = 0, motionInheritVariance: Float = 0, motionLive = false
    var initialAngleRange: Float = 0, rotationVariance: Float = 0, randomRotationDirection = false
    var onCycle: Float = 0, onCycleVariance: Float = 0, offCycle: Float = 0, offCycleVariance: Float = 0
    var startDelay: Float = 0, startDelayRandom = false, isOneShot = false
    var eliminateRandomness = false, noKillAtAlpha = false, alphaToKillAt: Float = 0
    var farClip: Float = 100
    /// 0 cámara (sin restricción), 1 XY, 2 XZ, 3 YZ (EffectParticleConstraint) [D].
    var axisConstraint = 0
    var texture = ""
    /// ParticleAnimationInfo: 0 sin animación; N = rejilla N×N; FPS; fotograma inicial al azar [D].
    var animType = 0, animFPS: Float = 0, randomStartFrame = false
    /// Curvas de vida (t = 0…1): color RGBA en bytes (0…255) y (medio tamaño en m, giro en unidades bAngle).
    var colour = LifeCurve(), extra = LifeCurve()
}

/// Polinomio cúbico por canal que pasa por 4 valores en u0…u3 (hermite_basis + hermite_parameter de bMatrix.cpp [D]).
/// `c[k]` = coeficientes (t³, t², t, 1) del canal k. Si las claves coinciden (matriz singular), interpolación lineal por tramos.
struct LifeCurve {
    var c: [float4] = [float4(0, 0, 0, 1), float4(0, 0, 0, 1), float4(0, 0, 0, 1), float4(0, 0, 0, 1)]
    var linear: [float4]? = nil      // valores por canal en las 4 claves (solo si es singular)
    var keys = float4(0, 1.0 / 3, 2.0 / 3, 1)

    init() {}
    /// `values[i]` = valor de los 4 canales en la clave i.
    init(values: [float4], keys k: float4) {
        keys = k
        // Resolver U·B = P (U filas [u³, u², u, 1]) en doble precisión con pivote parcial
        var U = (0..<4).map { i -> [Double] in let u = Double(k[i]); return [u * u * u, u * u, u, 1] }
        var P = (0..<4).map { i -> [Double] in (0..<4).map { Double(values[i][$0]) } }
        var singular = false
        for col in 0..<4 {
            var piv = col
            for r in col..<4 where abs(U[r][col]) > abs(U[piv][col]) { piv = r }
            if abs(U[piv][col]) < 1e-9 { singular = true; break }
            U.swapAt(col, piv); P.swapAt(col, piv)
            for r in 0..<4 where r != col {
                let f = U[r][col] / U[col][col]
                if f == 0 { continue }
                for j in 0..<4 { U[r][j] -= f * U[col][j]; P[r][j] -= f * P[col][j] }
            }
        }
        if singular { linear = (0..<4).map { ch in float4(values[0][ch], values[1][ch], values[2][ch], values[3][ch]) }; return }
        // B[fila] = coeficiente (t³, t², t, 1); por canal
        c = (0..<4).map { ch in float4((0..<4).map { Float(P[$0][ch] / U[$0][$0]) }) }
    }

    func eval(_ t: Float) -> float4 {
        if let l = linear {
            var out = float4.zero
            for ch in 0..<4 {
                let v = l[ch]
                if t <= keys[0] { out[ch] = v[0]; continue }
                if t >= keys[3] { out[ch] = v[3]; continue }
                var i = 0
                while i < 2 && t > keys[i + 1] { i += 1 }
                let span = max(keys[i + 1] - keys[i], 1e-6)
                out[ch] = v[i] + (v[i + 1] - v[i]) * (t - keys[i]) / span
            }
            return out
        }
        let u = float4(t * t * t, t * t, t, 1)
        return float4(simd_dot(c[0], u), simd_dot(c[1], u), simd_dot(c[2], u), simd_dot(c[3], u))
    }
}

struct EmitterGroupDef {
    var name: String
    var emitters: [Int]
    var farClip: Float
    var intensityRanges: [SIMD2<Float>]
}

/// TireEffectRecord {emisor, velocidad mínima, máxima} [D: MWAttribUserTypes.h].
struct TireEffectRecord { var group: String?; var minSpeed: Float; var maxSpeed: Float }

/// Emisor colocado (mundo o garaje del frontend): grupo, matriz local → mundo (o → interior) y disparadores por cercanía.
struct PlacedEmitter {
    var group: String
    var matrix: float4x4
    var triggers: [(pos: float3, radius: Float, reset: Float)]
}

/// Destello del mundo (eLightFlare de los marcadores 0x0013401A) [V]: tipo ELF_* y posición.
struct WorldFlare { var type: Int; var pos: float3 }

/// Una capa de ParameterMaps (0x8003B601) [V][D: World/ParameterMaps.cpp]: árbol cuaternario sobre `rect` y conjuntos de datos.
struct ParameterLayer {
    var name: String
    var rect: float4          // left, top, right, bottom
    var sets: [[Float]]
    var quads: [Int]
    /// ParameterMapLayer::GetParameterData (x, y del mundo): índice del conjunto. Hoja: hijo0 = 0, dato = hijo1 [V].
    func setIndex(x: Float, y: Float) -> Int {
        if quads.isEmpty { return 0 }
        var l = rect.x, t = rect.y, r = rect.z, b = rect.w
        var i = 0
        for _ in 0..<64 {
            guard i * 4 + 3 < quads.count else { return 0 }
            let q = quads[i * 4..<(i * 4 + 4)].map { $0 }
            if q[0] == 0 { return min(max(q[1], 0), sets.count - 1) }
            let cx = (l + r) / 2, cy = (t + b) / 2
            if x < cx { r = cx; if y < cy { b = cy; i = q[0] } else { t = cy; i = q[1] } }
            else { l = cx; if y < cy { b = cy; i = q[2] } else { t = cy; i = q[3] } }
        }
        return 0
    }
    func values(x: Float, y: Float) -> [Float] { sets.isEmpty ? [] : sets[setIndex(x: x, y: y)] }
}

final class EffectsLibrary {
    private static var cache: [String: EffectsLibrary] = [:]
    private static let lock = NSLock()

    private(set) var emitters: [EmitterDef] = []
    private(set) var emitterIndex: [String: Int] = [:]
    private(set) var groups: [String: EmitterGroupDef] = [:]
    /// Nombre de efecto (`effects` del VLT) → emittergroup (carexhaustnos → fxcar_nos…).
    private(set) var effectGroups: [String: String] = [:]
    /// simsurface → (TireSlideEffects, TireSlipEffects, TireDriveEffects).
    private(set) var tireEffects: [String: (slide: [TireEffectRecord], slip: [TireEffectRecord], drive: [TireEffectRecord])] = [:]
    private(set) var worldEmitters: [PlacedEmitter] = []
    private(set) var frontendEmitters: [String: [PlacedEmitter]] = [:]
    private(set) var flares: [WorldFlare] = []
    private(set) var layers: [String: ParameterLayer] = [:]
    /// Textura de partícula → 1 mezcla normal, 2 aditiva (AlphaBlendType del TPK «PARTICLE») [V].
    private(set) var textureBlend: [String: Int] = [:]
    let root: URL
    private(set) var loaded = false

    /// Biblioteca de la carpeta de datos (nil si falta effects.json: datos anteriores al formato 9).
    static func shared(_ data: GameData) -> EffectsLibrary? {
        lock.lock(); defer { lock.unlock() }
        if let l = cache[data.root.path] { return l.loaded ? l : nil }
        let l = EffectsLibrary(root: data.root)
        cache[data.root.path] = l
        return l.loaded ? l : nil
    }

    func particleTextureURL(_ name: String) -> URL { root.appendingPathComponent("effects/particles/\(name).png") }

    private init(root: URL) {
        self.root = root
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let d = try? Data(contentsOf: root.appendingPathComponent("effects.json")),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            fputs("efectos: no hay effects.json (datos anteriores al formato 9): sin partículas ni destellos del mundo\n", stderr)
            return
        }
        func f(_ v: Any?) -> Float { (v as? NSNumber)?.floatValue ?? 0 }
        func b(_ v: Any?) -> Bool { (v as? Bool) ?? ((v as? NSNumber)?.intValue ?? 0 != 0) }
        func v3(_ v: Any?) -> float3 { let a = (v as? [NSNumber]) ?? []; return float3(a.count > 0 ? a[0].floatValue : 0, a.count > 1 ? a[1].floatValue : 0, a.count > 2 ? a[2].floatValue : 0) }
        func v4(_ v: Any?) -> float4 { let a = (v as? [NSNumber]) ?? []; return float4((0..<4).map { $0 < a.count ? a[$0].floatValue : 0 }) }
        func mat(_ v: Any?) -> float4x4 {
            let a = ((v as? [NSNumber]) ?? []).map(\.floatValue)
            guard a.count == 16 else { return .identity }
            // bMatrix4 por filas (fila 3 = posición) = columnas de float4x4
            return float4x4(columns: (float4(a[0], a[1], a[2], a[3]), float4(a[4], a[5], a[6], a[7]), float4(a[8], a[9], a[10], a[11]), float4(a[12], a[13], a[14], a[15])))
        }
        func bytes(_ c: UInt32) -> float4 { float4(Float(c >> 24), Float((c >> 16) & 0xff), Float((c >> 8) & 0xff), Float(c & 0xff)) }

        if let tex = (j["particles"] as? [String: Any])?["textures"] as? [String: [String: Any]] {
            for (k, v) in tex { textureBlend[k] = (v["alphaBlend"] as? Int) ?? 1 }
        }
        let lib = j["library"] as? [String: Any] ?? [:]
        for (name, any) in (lib["emitterData"] as? [String: [String: Any]] ?? [:]).sorted(by: { $0.key < $1.key }) {
            let e = any
            var d = EmitterDef()
            d.name = name
            d.life = f(e["Life"]); d.lifeVariance = f(e["LifeVariance"])
            d.numParticles = f(e["NumParticles"]); d.numParticlesVariance = f(e["NumParticlesVariance"])
            d.speed = f(e["Speed"]); d.speedVariance = f(e["SpeedVariance"])
            d.spreadAngle = f(e["SpreadAngle"]); d.spreadAsDisc = b(e["SpreadAsDisc"])
            d.velStart = v3(e["VelocityStart"]); d.velDelta = v3(e["VelocityDelta"])
            d.accStart = v3(e["AccelStart"]); d.accDelta = v3(e["AccelDelta"])
            d.volCenter = v3(e["VolumeCenter"]); d.volExtent = v3(e["VolumeExtent"])
            d.gravity = f(e["Gravity"]); d.drag = f(e["Drag"])
            d.motionInherit = f(e["MotionInherit"]); d.motionInheritVariance = f(e["MotionInheritVariance"]); d.motionLive = b(e["MotionLive"])
            d.initialAngleRange = f(e["InitialAngleRange"]); d.rotationVariance = f(e["RotationVariance"]); d.randomRotationDirection = b(e["RandomRotationDirection"])
            d.onCycle = f(e["OnCycle"]); d.onCycleVariance = f(e["OnCycleVariance"]); d.offCycle = f(e["OffCycle"]); d.offCycleVariance = f(e["OffCycleVariance"])
            d.startDelay = f(e["StartDelay"]); d.startDelayRandom = b(e["StartDelayRandomVariance"]); d.isOneShot = b(e["IsOneShot"])
            d.eliminateRandomness = b(e["EliminateUnnecessaryRandomness"]); d.noKillAtAlpha = b(e["NoKillAtAlpha"]); d.alphaToKillAt = f(e["AlphaToKillAt"])
            d.farClip = f(e["FarClip"])
            d.axisConstraint = (e["AxisConstraint"] as? NSNumber)?.intValue ?? 0
            d.texture = (e["Texture"] as? [String: Any])?["texture"] as? String ?? ""
            if let a = e["TextureAnimation"] as? [String: Any] {
                d.animType = (a["animType"] as? NSNumber)?.intValue ?? 0; d.animFPS = f(a["fps"]); d.randomStartFrame = b(a["randomStartFrame"])
            }
            // CalculateBases [D]: claves = KeyPositions/3; color en bytes; extra = (Size/2, RelativeAngle × 182,04 en bAngle)
            let keys = v4(e["KeyPositions"]) / 3
            let cols = ["Color1", "Color2", "Color3", "Color4"].map { bytes(UInt32(truncatingIfNeeded: (e[$0] as? NSNumber)?.int64Value ?? 0)) }
            d.colour = LifeCurve(values: cols, keys: keys)
            let size = v4(e["Size"]) * 0.5, rel = v4(e["RelativeAngle"]) * 182.04445
            d.extra = LifeCurve(values: (0..<4).map { float4(size[$0], rel[$0], 0, 0) }, keys: keys)
            emitterIndex[name] = emitters.count
            emitters.append(d)
        }
        for (name, g) in lib["emitterGroups"] as? [String: [String: Any]] ?? [:] {
            let ems = (g["Emitters"] as? [Any] ?? []).compactMap { e -> Int? in
                let n = (e as? String) ?? ((e as? [String: Any])?["collection"] as? String)
                return n.flatMap { emitterIndex[$0] }
            }
            let ranges = (g["IntensityRanges"] as? [[NSNumber]] ?? []).map { SIMD2<Float>($0.count > 0 ? $0[0].floatValue : 0, $0.count > 1 ? $0[1].floatValue : 0) }
            groups[name] = EmitterGroupDef(name: name, emitters: ems, farClip: f(g["FarClip"]), intensityRanges: ranges)
        }
        for (name, e) in lib["effects"] as? [String: [String: Any]] ?? [:] { if let g = e["emittergroup"] as? String { effectGroups[name] = g } }
        for (surf, s) in lib["tireEffectsBySurface"] as? [String: [String: Any]] ?? [:] {
            func recs(_ k: String) -> [TireEffectRecord] {
                (s[k] as? [[String: Any]] ?? []).map { TireEffectRecord(group: $0["emitter"] as? String, minSpeed: f($0["minSpeed"]), maxSpeed: f($0["maxSpeed"])) }
            }
            tireEffects[surf] = (recs("TireSlideEffects"), recs("TireSlipEffects"), recs("TireDriveEffects"))
        }
        func placed(_ a: [[String: Any]]) -> [PlacedEmitter] {
            a.compactMap { e in
                guard let g = e["group"] as? String, groups[g] != nil else { return nil }
                let trig = (e["triggers"] as? [[String: Any]] ?? []).map { (pos: v3($0["pos"]), radius: f($0["radius"]), reset: f($0["reset"])) }
                return PlacedEmitter(group: g, matrix: mat(e["matrix"]), triggers: trig)
            }
        }
        worldEmitters = placed(j["worldEmitters"] as? [[String: Any]] ?? [])
        for (k, a) in j["frontendEmitters"] as? [String: [[String: Any]]] ?? [:] { frontendEmitters[k] = placed(a) }
        flares = (j["flares"] as? [[String: Any]] ?? []).compactMap { e in
            guard !b(e["hidden"]) else { return nil }
            return WorldFlare(type: (e["type"] as? NSNumber)?.intValue ?? 0, pos: v3(e["pos"]))
        }
        for p in j["parameterMaps"] as? [[String: Any]] ?? [] {
            guard let n = p["name"] as? String else { continue }
            let sets = (p["sets"] as? [[NSNumber]] ?? []).map { $0.map(\.floatValue) }
            layers[n] = ParameterLayer(name: n, rect: v4(p["rect"]), sets: sets, quads: (p["quads"] as? [NSNumber] ?? []).map(\.intValue))
        }
        loaded = true
        print(String(format: "efectos: %d emisores, %d grupos, %d en el mundo, %d destellos, %d capas de parámetros (%.0f ms)",
                     emitters.count, groups.count, worldEmitters.count, flares.count, layers.count, (CFAbsoluteTimeGetCurrent() - t0) * 1000))
    }

    func emitter(_ i: Int) -> EmitterDef { emitters[i] }
}
