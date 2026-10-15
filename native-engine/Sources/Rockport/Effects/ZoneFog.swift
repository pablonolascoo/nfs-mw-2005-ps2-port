// Niebla y tinte de pantalla por zona (ParameterMaps, doc 24 §6.2) con la mezcla del juego:
//  - Capas «Normal Fog» (8 floats, 3 conjuntos), «Screen Tint Midday» (RGB) y «Fog Blend Distance» (50 m) [V].
//  - ParameterAccessorBlendByDistance::CaptureData [D: World/ParameterMaps.cpp]: cada fotograma el valor se acerca al de la zona
//    donde está la cámara en la proporción recorrido / distancia de mezcla (con 50 m de mezcla, cruzar a otra zona tarda 50 m).
//    Un accesor por vista (FogAccessor[2], TintMiddayAccessor[2] [D]: uno por jugador).
//  - Qué es cada campo de la niebla: FogQuery::CalculateFogInfo está vacía en la decomp [D]. Lectura [I]: [0] densidad máxima,
//    [1] inicio (m), [2…4] color RGB (0…255), [5] caída (más alta = se cierra antes); [6] y [7] sin uso conocido [H].
import Foundation
import simd

final class ZoneFog {
    final class Accessor {
        var last: [Float]? = nil
        var lastXY: SIMD2<Float>? = nil
        /// CaptureData(x, y, fullBlendDistance) [D].
        func capture(_ layer: ParameterLayer, x: Float, y: Float, blend: Float) -> [Float] {
            let cur = layer.values(x: x, y: y)
            var ratio: Float = 1
            if let l = lastXY, blend != 0 {
                let d = simd_distance(l, SIMD2(x, y))
                if d < blend { ratio = d / blend }
            }
            lastXY = SIMD2(x, y)
            guard var prev = last, prev.count == cur.count else { last = cur; return cur }
            for i in prev.indices { prev[i] = cur[i] * ratio + prev[i] * (1 - ratio) }
            last = prev
            return prev
        }
    }
    let fog: ParameterLayer?
    let tint: ParameterLayer?
    let blendDistance: Float
    private var fogAcc: [Accessor] = []
    private var tintAcc: [Accessor] = []

    init(library: EffectsLibrary) {
        fog = library.layers["Normal Fog"]
        tint = library.layers["Screen Tint Midday"]
        blendDistance = library.layers["Fog Blend Distance"]?.sets.first?.first ?? 50
    }

    /// Niebla de la calle para la vista `view` (0 = jugador 1) en `pos`: (inicio, escala, máximo, activo) y color sRGB.
    func fog(view: Int, at pos: float3) -> (params: float4, colour: float3)? {
        guard let layer = fog else { return nil }
        while fogAcc.count <= view { fogAcc.append(Accessor()) }
        let v = fogAcc[view].capture(layer, x: pos.x, y: pos.y, blend: blendDistance)
        guard v.count >= 6 else { return nil }
        // Escala [I]: 2600 m con la caída 0,75 del primer conjunto (el ajuste a ojo de doc 20 §2), inversa a la caída
        let scale = 2600 * 0.75 / max(v[5], 0.05)
        return (float4(v[1], scale, min(max(v[0], 0), 1), 1), float3(v[2], v[3], v[4]) / 255)
    }

    /// Tinte de pantalla (RGB 0…255) para la vista `view`.
    func tint(view: Int, at pos: float3) -> float3? {
        guard let layer = tint else { return nil }
        while tintAcc.count <= view { tintAcc.append(Accessor()) }
        let v = tintAcc[view].capture(layer, x: pos.x, y: pos.y, blend: blendDistance)
        return v.count >= 3 ? float3(v[0], v[1], v[2]) : nil
    }
}
