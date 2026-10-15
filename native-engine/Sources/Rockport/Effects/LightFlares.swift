// Destellos de luz (eLightFlare) del juego:
//  - Mundo: 2 242 destellos de los marcadores de sólido (0x0013401A, doc 24 §4) [V]: semáforos ámbar/rojo/verde intermitentes y
//    catadióptricos. En el PS2 no hay destellos de farola (ELF_LAMPPOST no aparece en ningún marcador y `lamppost_outer` tiene
//    color 0) [V].
//  - Coches: marcadores LEFT/RIGHT/CENTRE_HEADLIGHT, *_BRAKELIGHT, *_REVERSE y COPLIGHT* del modelo (CreateCarLightFlares [D])
//    con las intensidades de RenderFlaresOnCar [D]: faros 1, pilotos 0,5 (+16 al frenar, tope 1), barra de luces con
//    coplightflicker2 (rojo/azul alternos a 8 rad/s, pulso cos²(24 t), blanco = sin(3·parpadeo)).
//  - Parámetros por tipo: atributos `light_flares_cg` (color, tamaños, escala, potencia, ZBias, textura) [V: fx.json].
//  - Intermitentes: eResestLightFlarePool [D]: tres relojes que cambian cada 0,5 / 0,4 / 0,45 s; ámbar usa el de |x| mod 3, rojo el
//    primero y verde el tercero.
// El dibujo de eRenderLightFlare es código de PS2 sin decompilar: tamaño en pantalla, atenuación por ángulo y la oclusión son [I]
// (cuadrado aditivo de cara a la cámara, adelantado ZBias m y con prueba de profundidad).
import Foundation
import simd

/// Parámetros de `light_flares_cg` [V].
struct FlareParams {
    var colour = float4.zero
    var minSize: Float = 0, maxSize: Float = 0, minScale: Float = 0, maxScale: Float = 0
    var power: Float = 1, zBias: Float = 0
    var texture = 2
}

/// Instancia de destello para la GPU (`FlareInst` de EffectsRenderer.swift).
struct FlareInstance {
    var posRadius: float4     // xyz mundo, w radio en el mundo (m)
    var colour: float4        // rgb = color del vértice (escala del GS, 1 = 128), a = textura (0, 1, 2)
    var misc: float4          // x ZBias (m), y peso de la suma (As)
}

final class LightFlares {
    private(set) var params: [Int: (inner: FlareParams?, outer: FlareParams?)] = [:]
    let world: [WorldFlare]
    private(set) var blink: [Bool] = [false, false, false]
    private var blinkTime: [Float] = [0, 0, 0]
    let data: GameData
    /// Halo de la barra de luces (tamaño ×10 del juego [D]; peso propio [I]).
    static var copHaloScale: Float = 6, copHaloWeight: Float = 0.15

    init(data: GameData, world: [WorldFlare]) {
        self.data = data
        self.world = world
        var byName: [String: FlareParams] = [:]
        if let d = try? Data(contentsOf: data.url("fx/fx.json")), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let a = (j["attribs"] as? [String: Any])?["light_flares_cg"] as? [String: [String: Any]] {
            func f(_ v: Any?) -> Float { (v as? NSNumber)?.floatValue ?? 0 }
            for (k, v) in a {
                let c = (v["colour"] as? [NSNumber] ?? []).map(\.floatValue)
                byName[k] = FlareParams(colour: c.count == 4 ? float4(c[0], c[1], c[2], c[3]) : .zero, minSize: f(v["MinSize"]), maxSize: f(v["MaxSize"]),
                                        minScale: f(v["MinScale"]), maxScale: f(v["Maxscale"]), power: f(v["Power"]), zBias: f(v["ZBias"]),
                                        texture: (v["flare_texture"] as? NSNumber)?.intValue ?? 2)
            }
        }
        // ELF_* → atributo [I: por nombre]
        let map: [Int: (String?, String?)] = [
            0: ("headlight_inner", "headlight_outer"), 1: ("brakelight_inner", nil), 2: ("brakelight_traffic_inner", nil),
            3: ("reverselight_inner", nil), 4: ("foglight_inner", nil), 5: ("coplightred_inner", nil), 6: ("coplightblue_inner", nil),
            7: ("coplightwhite_inner", nil), 10: ("coplightbrightred", nil), 11: ("coplightbrightblue", nil), 12: ("coplightorange", nil),
            13: ("lamppost_inner", "lamppost_outer"), 14: ("catseye_orange", nil), 15: ("catseye_red", nil), 16: ("catseye_blue", nil),
            17: ("traffic_light", nil), 18: ("traffic_light_red", nil), 19: ("green_flare", nil), 20: ("hand_flare_red", nil), 21: ("sun_flare", nil)]
        for (t, n) in map { params[t] = (n.0.flatMap { byName[$0] }, n.1.flatMap { byName[$0] }) }
    }

    /// eResestLightFlarePool [D]: relojes de los intermitentes.
    func tick(_ dt: Float) {
        let periods: [Float] = [0.5, 0.4, 0.45]
        for i in 0..<3 { blinkTime[i] += dt; if blinkTime[i] > periods[i] { blinkTime[i] = 0; blink[i].toggle() } }
    }

    private func blinkOn(_ type: Int, x: Float) -> Bool {
        switch type {
        case 17: return blink[abs(Int(x) % 3)]
        case 18: return blink[0]
        case 19: return blink[2]
        default: return true
        }
    }

    /// Un destello: tamaño en píxeles de una pantalla de 480 líneas (la del PS2) pasado a metros a esa distancia [I].
    func add(_ out: inout [FlareInstance], type: Int, pos: float3, dir: float3?, intensity: Float, cam: float3, projY: Float, sizeScale: Float = 1) {
        guard intensity > 0, let pr = params[type] else { return }
        let to = cam - pos
        let dist = simd_length(to)
        guard dist > 0.3 else { return }
        for (p, outer) in [(pr.inner, false), (pr.outer, true)] {
            guard let p, p.colour.w > 0, p.maxSize + p.minSize > 0 else { continue }
            var k = intensity
            if let dir {   // luces con dirección (faros, pilotos): se ven de frente [I]
                let f = max(0, simd_dot(simd_normalize(dir), to / dist))
                k *= pow(f, max(p.power, 0.05))
            }
            if k < 0.01 { continue }
            let near = min(1, max(0.35, 30 / dist))
            let px = max(p.minSize, p.maxSize) * (0.35 + 0.65 * min(k, 1)) * near * sizeScale * (outer ? 1.0 : 1.0)
            let radius = px * 0.5 / 240 * dist / max(projY, 0.1)   // MinSize/MaxSize como diámetro en píxeles [I]
            // Brillo [I]: color del atributo (0…1 = 0…255; en el GS 128 = 1, así que ×2) modula la textura (Cs, satura) y el alfa
            // (×2) es el peso de la suma (As), por la intensidad y una atenuación de cerca y de lejos
            let fade = min(1, (dist - 0.3) / 2) * (1 - min(1, max(0, (dist - 500) / 300)))
            let As = p.colour.w * 2 * min(k, 1) * fade
            out.append(FlareInstance(posRadius: float4(pos, radius), colour: float4(float3(p.colour.x, p.colour.y, p.colour.z) * 2, Float(p.texture)),
                                     misc: float4(p.zBias, As, 0, 0)))
        }
    }

    /// Destellos del mundo cerca de la cámara y dentro del frustum.
    func gatherWorld(_ out: inout [FlareInstance], frustum: Frustum, cam: float3, projY: Float) {
        for f in world {
            let d2 = simd_distance_squared(f.pos, cam)
            if d2 > 800 * 800 { continue }
            if !frustum.intersects(AABB(min: f.pos - 1, max: f.pos + 1)) { continue }
            guard blinkOn(f.type, x: f.pos.x) else { continue }
            add(&out, type: f.type, pos: f.pos, dir: nil, intensity: 1, cam: cam, projY: projY)
        }
    }

    // MARK: Coches

    /// Tipo ELF de un marcador del coche (CreateCarLightFlares [D]); nil si no es una luz.
    static func flareType(_ name: String) -> Int? {
        switch name {
        case "LEFT_HEADLIGHT", "RIGHT_HEADLIGHT", "CENTRE_HEADLIGHT", "9db90133", "7a5bcf69": return 0
        case "LEFT_BRAKELIGHT", "RIGHT_BRAKELIGHT", "CENTRE_BRAKELIGHT", "a2a2fc7c": return 1
        case "LEFT_REVERSE", "RIGHT_REVERSE": return 3
        case "COPLIGHTRED", "1e4150b4": return 5
        case "COPLIGHTBLUE", "e662c161": return 6
        case "COPLIGHTWHITE", "b4348dba": return 7
        case "COPLIGHTBRIGHTRED", "41489594": return 10
        case "COPLIGHTBRIGHTBLUE", "6a52a241": return 11
        case "COPLIGHTORANGE", "28cd78f5": return 12
        default: return nil
        }
    }

    /// coplightflicker / coplightflicker2 [D: CarRender.cpp 2365-2423].
    static func copFlicker(_ t: Float, color: Int, count: Int) -> Float {
        let c = cos(24 * t)
        let pulse = c * c
        if color == 2 { return pulse * cos((t + 1.5 * Float(count)) * 12) }
        let offset: Float = color == 0 ? 0 : .pi
        return cos(t * 8 + offset) > 0.2 ? pulse : 0
    }

    /// RenderFlaresOnCar [D]: luces de un coche con su matriz (espacio del GLB → mundo).
    func gatherCar(_ out: inout [FlareInstance], model: String, body: float4x4, traffic: Bool, braking: Bool, reversing: Bool,
                   copLights: Bool, time: Float, cam: float3, projY: Float) {
        let markers = CarMarkers.of(model, data: data)
        var r: Float = 1, b: Float = 1
        var count = 0
        let rot = simd_float3x3(float3(body.columns.0.x, body.columns.0.y, body.columns.0.z), float3(body.columns.1.x, body.columns.1.y, body.columns.1.z),
                                float3(body.columns.2.x, body.columns.2.y, body.columns.2.z))
        for m in markers {
            guard var type = LightFlares.flareType(m.name) else { continue }
            if traffic && type == 1 { type = 2 }
            var k: Float = 0
            switch type {
            case 0: k = 1
            case 1, 2: k = min(1, 0.5 + (braking ? 16 : 0))
            case 3: k = reversing ? 1 : 0
            case 5: if copLights { r *= LightFlares.copFlicker(time, color: 0, count: count); k = r }
            case 6: if copLights { b *= LightFlares.copFlicker(time, color: 1, count: count); k = b }
            case 10: if copLights { k = LightFlares.copFlicker(time, color: 0, count: count) }
            case 11: if copLights { k = LightFlares.copFlicker(time, color: 1, count: count) }
            case 7: if copLights { k = sin(LightFlares.copFlicker(time, color: 2, count: count) * 3) }
            case 12: k = copLights ? 1 : 0
            default: break
            }
            count += 1
            let wp = body * m.matrix.columns.3
            // Barra de luces: sin dirección; faros y pilotos: eje Z del marcador
            let dir: float3? = (5...12).contains(type) ? nil : simd_normalize(rot * float3(m.matrix.columns.2.x, m.matrix.columns.2.y, m.matrix.columns.2.z))
            add(&out, type: type, pos: float3(wp.x, wp.y, wp.z), dir: dir, intensity: k, cam: cam, projY: projY)
            // Halo de la barra de luces: RenderFlaresOnCar con renderFlareFlags & 1 vuelve a dibujar solo las luces de policía
            // (tipos 5…12) ×10 de tamaño en FLARE_ENV [D]; aquí con la textura HEADLIGHTGLOW y la cuarta parte del peso [I]
            if (5...12).contains(type), k > 0 {
                let n = out.count
                add(&out, type: type, pos: float3(wp.x, wp.y, wp.z), dir: nil, intensity: k, cam: cam, projY: projY, sizeScale: LightFlares.copHaloScale)
                for i in n..<out.count { out[i].colour.w = 0; out[i].misc.y *= LightFlares.copHaloWeight; out[i].misc.x = 0.5 }
            }
        }
    }
}
