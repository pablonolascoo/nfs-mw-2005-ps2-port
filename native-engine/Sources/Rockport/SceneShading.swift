// Luz y efectos del juego (doc 20): lo que comparten todos los shaders de escena y los datos de `fx/` (tools/src/cli/fx.ts).
//
// 1. Espacio de color de la escena = el del PS2. El GS mezcla en espacio de pantalla (gamma): sombras horneadas, calcomanías,
//    rayos de luz aditivos y la niebla se suman o mezclan sobre valores ya codificados [D: GS, alfa (Cs−Cd)·As + Cd].
//    Por eso cada shader de escena calcula su color en lineal (texturas sRGB → lineal al muestrear) y lo **escribe codificado**
//    (`sceneOut`), y el `fs_post` ya no codifica. Mezclar en lineal aclaraba las sombras `SHD_*` (con alfa 0,5: 0,73 en pantalla en
//    vez de 0,5) y convertía los rayos de luz aditivos del refugio en cajas verdes opacas (0,17 lineal ≈ +115/255).
// 2. Coches: el material de luz del juego de cada tira (eLightMaterial: difusa, especular y mapa de entorno con mínimo/máximo) y el
//    mapa de entorno esférico del garaje (<GARAJE>_CARSELECTENVMAP) o del cielo (SMALLENVMAP), con el brillo de la piel (alfa = GLOSS).
// 3. Luces: ambiente de dos colores + hasta 3 direccionales (el juego usa «shaper rigs» de 4 luces por garaje; sus valores están en
//    BSS y no se han localizado: los de aquí son [I], ajustados a capturas del juego).
import Foundation
import Metal
import simd

/// Prólogo MSL común a Shaders.swift, AIRender.swift y Garage/GarageRender.swift. Debe coincidir con `FrameUniforms` y
/// `LightMaterialGPU` de Swift (mismo orden, todo float4/float4x4).
let scenePreludeMSL = """
#include <metal_stdlib>
using namespace metal;

struct FrameUniforms {
    float4x4 viewProj;
    float4x4 invViewProj;
    float4   camPos;      // xyz cámara, w tiempo (s)
    float4   fog;         // x inicio (m), y escala (m), z máximo, w activo
    float4   fogColor;    // lineal
    float4   skyHorizon;  // lineal
    float4   skyHaze;
    float4   skyZenith;
    float4   sunDir;      // xyz hacia el sol (desde la cámara), w 1 si hay sol
    float4   lightSky;    // ambiente de arriba (lineal)
    float4   lightGround; // ambiente de abajo
    float4   lightSun;    // -
    float4x4 view;        // mundo → vista (reflejos en espacio de vista)
    float4   lightDir[3]; // direccionales (hacia la luz)
    float4   lightCol[3]; // color × intensidad (lineal)
    float4   env;         // x modo del reflejo (0 no, 1 esfera de vista, 2 cielo), y fuerza, z alfa de la sombra del coche, w FE
    float4   fogHeight;   // x z del suelo, y espesor (m), z densidad, w distancia a la que llega al máximo
};

// Lineal → espacio del PS2 (sRGB). Satura como el GS (0…255).
static float3 ps2Encode(float3 c) {
    c = saturate(c);
    return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
}

// Niebla: exponencial con la distancia (con tope) + bruma baja junto al suelo (garajes del frontend).
static float fogFactor(constant FrameUniforms& F, float3 world) {
    if (F.fog.w < 0.5) return 0;
    float d = distance(world, F.camPos.xyz);
    float k = (1.0 - exp(-max(d - F.fog.x, 0.0) / F.fog.y)) * F.fog.z;
    if (F.fogHeight.z > 0) {
        float h = 1.0 - saturate((world.z - F.fogHeight.x) / F.fogHeight.y);
        k = max(k, h * h * F.fogHeight.z * saturate(d / F.fogHeight.w));
    }
    return saturate(k);
}

// Color final de la escena: niebla y codificación (la mezcla posterior ocurre en espacio de pantalla, como en el PS2).
static float3 sceneRGB(constant FrameUniforms& F, float3 lin, float3 world) {
    return mix(ps2Encode(lin), ps2Encode(F.fogColor.rgb), fogFactor(F, world));
}

// Material de luz del juego (eLightMaterialData, 30 floats [V][D]): mínimo y máximo de difusa (rgb × escala, a = alfa),
// especular y entorno, y p = (SpecularPower, EnvmapPower, MetallicScale, alfa = brillo de la piel).
struct LightMat { float4 dMin; float4 dMax; float4 sMin; float4 sMax; float4 eMin; float4 eMax; float4 p; };

// Sombreado de coche. Interpretación [I] de eLightMaterialData (el código de PS2 que lo usa no está decompilado):
// t = N·V (1 de frente, 0 de canto); difusa y especular van de Min (canto) a Max (frente); el entorno con t^EnvmapPower,
// así METPAINTSILVER refleja ×0,2 de frente y ×3,5 en los cantos (efecto Fresnel del juego). Exponente especular 2^(Power+2).
static float4 carShade(constant FrameUniforms& F, constant LightMat& M, float4 base, float gloss, float3 n, float3 world,
                       texture2d<float> env, sampler es) {
    float3 v = normalize(F.camPos.xyz - world);
    if (dot(n, v) < 0) n = -n;
    float NV = saturate(dot(n, v));
    float3 r = reflect(-v, n);
    float3 lit = mix(F.lightGround.rgb, F.lightSky.rgb, 0.5 * n.z + 0.5);
    float3 spec = 0;
    float e = exp2(clamp(M.p.x, 0.0, 9.0) + 2.0);
    for (int i = 0; i < 3; i++) {
        float3 L = F.lightDir[i].xyz;
        lit += F.lightCol[i].rgb * saturate(dot(n, L));
        spec += F.lightCol[i].rgb * pow(saturate(dot(r, L)), e);
    }
    float3 D = mix(M.dMin.rgb, M.dMax.rgb, NV);
    float3 S = mix(M.sMin.rgb, M.sMax.rgb, NV);
    float3 c = base.rgb * D * lit + S * spec * gloss;
    if (F.env.x > 0.5) {
        float2 uv;
        if (F.env.x < 1.5) {                       // mapa esférico en espacio de vista (elSetupEnvMap: matriz local → vista)
            float3 rv = (F.view * float4(r, 0)).xyz;
            float m = 2.0 * sqrt(rv.x * rv.x + rv.y * rv.y + (rv.z + 1.0) * (rv.z + 1.0));
            uv = float2(rv.x / m + 0.5, 0.5 - rv.y / m);
        } else {                                   // cielo: acimut y elevación (mitad de arriba cielo, abajo suelo oscuro) [I]
            uv = float2(atan2(r.y, r.x) * (0.5 / M_PI_F) + 0.5, 0.5 - asin(clamp(r.z, -1.0, 1.0)) / M_PI_F);
        }
        float3 ec = env.sample(es, uv).rgb;
        ec *= ec * 1.6;   // contraste del reflejo [I]: luces del techo y cielo enteros, tonos medios del garaje apagados
        float t = pow(max(NV, 1e-3), max(M.p.y, 0.01));
        float3 E = mix(M.eMin.rgb, M.eMax.rgb, t);
        float mx = max(base.r, max(base.g, base.b));
        float3 tint = mix(float3(1.0), saturate(base.rgb / max(mx, 0.04)), 0.5 * saturate(M.p.z));   // metalizados: reflejo teñido [I]
        c += ec * E * tint * gloss * F.env.y;
    }
    return float4(c, base.a * mix(M.dMin.a, M.dMax.a, NV));
}
"""

/// Uniformes por fotograma (deben coincidir con `FrameUniforms` de `scenePreludeMSL`).
struct FrameUniforms {
    var viewProj: float4x4
    var invViewProj: float4x4
    var camPos: float4
    var fog: float4
    var fogColor: float4
    var skyHorizon: float4
    var skyHaze: float4
    var skyZenith: float4
    var sunDir: float4
    var lightSky: float4
    var lightGround: float4
    var lightSun: float4
    var view: float4x4 = .identity
    var lightDir0: float4 = .zero, lightDir1: float4 = .zero, lightDir2: float4 = .zero
    var lightCol0: float4 = .zero, lightCol1: float4 = .zero, lightCol2: float4 = .zero
    var env: float4 = .zero
    var fogHeight: float4 = .zero
}

/// Material de luz en GPU (`LightMat` de MSL).
struct LightMaterialGPU {
    var dMin = float4(1, 1, 1, 1), dMax = float4(1, 1, 1, 1)
    var sMin = float4(0.15, 0.15, 0.15, 0), sMax = float4(0.05, 0.05, 0.05, 0)
    var eMin = float4.zero, eMax = float4.zero
    var p = float4(2, 1, 0, 0)
    /// Sin material del juego (piezas sin `extras.luz`): difusa plena, poco brillo, sin reflejo.
    static let neutral = LightMaterialGPU()
}

/// Luz de una vista: ambiente, direccionales, reflejos, niebla. `world` = calle; `frontEnd(...)` = garajes y menús.
struct SceneLighting {
    var ambientSky = float3(0.42, 0.42, 0.45)       // lineal
    var ambientGround = float3(0.16, 0.14, 0.11)
    var lights: [(dir: float3, color: float3)] = []  // dir hacia la luz (mundo); nil = sol de fx.json
    var useSun = true                                // la primera luz es el sol (dirección desde la cámara al SunChunkInfo)
    var sunColor = float3(1.0, 0.86, 0.66)
    var envMap = "SMALLENVMAP"
    var envMode: Float = 2
    var envStrength: Float = 1
    var shadowAlpha: Float = 100.0 / 128.0           // CarBaseShadowAlphaMaxIG = 100 (0x80 = opaco) [D]
    /// Niebla de la calle: inicio 200 m y tope 0,5–0,6 como el primer juego de «Normal Fog» de los ParameterMaps
    /// (0,5 · 200 · gris 128 …, doc 24 §6.2) [V: valores; I: significado de cada campo]; escala 2600 m [I].
    var fog = float4(200, 2600, 0.6, 1)
    var fogColor: float3? = nil                      // nil = horizonte del cielo
    var fogHeight = float4.zero
    var frontEnd = false
    var sky = true                                   // pintar el cielo del juego (fs_sky)

    static let world = SceneLighting()

    /// Garajes del frontend [I]: luz principal cálida desde arriba a un lado (ventanas), relleno frío, contraluz; reflejo con el
    /// mapa esférico del garaje [V: GLOBAL\DYNTEX.BIN] y sombra del coche a alfa 255 (CarBaseShadowAlphaMinFE/MaxFE) [D].
    static func frontEnd(_ interior: String) -> SceneLighting {
        var l = SceneLighting()
        l.frontEnd = true
        l.useSun = false
        l.envMode = 1
        l.shadowAlpha = 1
        l.sky = false
        l.fog = float4(0, 1, 0, 0)
        switch interior {
        case "CAREER_SAFEHOUSE":
            l.envMap = "CAREER_CARSELECTENVMAP"
            l.ambientSky = float3(0.30, 0.30, 0.26); l.ambientGround = float3(0.10, 0.09, 0.06)
            l.lights = [(simd_normalize(float3(-0.5, 0.6, 0.65)), float3(1.05, 0.92, 0.62)), (simd_normalize(float3(0.7, -0.4, 0.35)), float3(0.18, 0.22, 0.24)),
                        (simd_normalize(float3(0.1, -0.9, 0.5)), float3(0.25, 0.22, 0.15))]
        case "CUSTOMIZATION_SHOP", "CUSTOMIZATION_SHOP_BACKROOM":
            l.envMap = "CSHOP_CARSELECTENVMAP"
            l.ambientSky = float3(0.34, 0.33, 0.27); l.ambientGround = float3(0.12, 0.11, 0.07)
            l.lights = [(simd_normalize(float3(-0.6, 0.5, 0.6)), float3(1.0, 0.92, 0.74)), (simd_normalize(float3(0.6, -0.5, 0.4)), float3(0.2, 0.22, 0.2)),
                        (simd_normalize(float3(0, 0, 1)), float3(0.25, 0.23, 0.18))]
        case "CAR_LOT":
            l.envMap = "CARLOT_CARSELECTENVMAP"
            l.ambientSky = float3(0.42, 0.42, 0.40); l.ambientGround = float3(0.14, 0.13, 0.11)
            l.lights = [(simd_normalize(float3(0, 0.2, 1)), float3(0.75, 0.74, 0.7)), (simd_normalize(float3(-0.7, 0.5, 0.4)), float3(0.35, 0.33, 0.28)),
                        (simd_normalize(float3(0.6, -0.6, 0.3)), float3(0.18, 0.2, 0.22))]
        default:   // PLATFORMCRIB (menú principal, carrera rápida): azotea con cielo nublado amarillento
            l.envMap = "QRACE_CARSELECTENVMAP"
            l.ambientSky = float3(0.36, 0.34, 0.26); l.ambientGround = float3(0.10, 0.09, 0.06)
            l.lights = [(simd_normalize(float3(-0.4, 0.7, 0.55)), float3(1.0, 0.86, 0.52)), (simd_normalize(float3(0.8, -0.3, 0.3)), float3(0.16, 0.17, 0.18)),
                        (simd_normalize(float3(0.2, -0.6, 0.8)), float3(0.22, 0.2, 0.14))]
            l.fogHeight = float4(0, 1.6, 0.55, 18)   // bruma baja amarilla del menú [I: capturas del juego]
            l.fog = float4(40, 260, 0.55, 1)
            l.fogColor = float3(0.42, 0.36, 0.17)
        }
        return l
    }
}

/// Curva de Bézier de los atributos `visuallook` (GetValueFromSpline: solo las y de los 4 puntos) [D: VisualTreatment.cpp].
struct LookCurve { var y: float4 }

/// Datos de `fx/` (tools/src/cli/fx.ts): materiales de luz, tratamiento visual, sol y texturas. Uno por carpeta de datos.
final class FXData {
    private static var cache: [String: FXData] = [:]
    private static let lock = NSLock()

    let root: URL
    private(set) var materials: [String: LightMaterialGPU] = [:]
    /// Tratamiento visual (visuallook «default»: Midday 0xEEC2271A no está en el disco PAL y el VLT cae en «default» [V]).
    private(set) var bloomTint = float3(0.87, 0.68, 0.04)
    private(set) var bloomIntensity: Float = 0.32
    private(set) var bloomCurve = LookCurve(y: float4(0, -0.1206896, 1.068966, 0.9482759))
    private(set) var blackBloomIntensity: Float = 0.38
    private(set) var blackBloomCurve = LookCurve(y: float4(0, -0.137931, 1.189655, 0.9482759))
    private(set) var desaturation: Float = 0.25
    /// Sol MIDDAY (SunChunkInfo): posición en el mundo y capas (textura 0 centro, 1 halo; 2–4 rayos y anillo, sin textura en el disco).
    private(set) var sunPosition = float3(5300, -3550, 3000)
    private(set) var sunLayers: [(texture: Int, size: Float, color: float4, intensity: Float)] = []
    private(set) var loaded = false

    static func shared(_ data: GameData) -> FXData {
        lock.lock(); defer { lock.unlock() }
        if let f = cache[data.root.path] { return f }
        let f = FXData(root: data.url("fx"))
        cache[data.root.path] = f
        return f
    }

    private init(root: URL) {
        self.root = root
        guard let d = try? Data(contentsOf: root.appendingPathComponent("fx.json")),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            fputs("fx: no hay fx/fx.json (datos anteriores al formato 8): luz por defecto\n", stderr)
            return
        }
        loaded = true
        func f(_ v: Any?) -> Float { Float((v as? Double) ?? Double((v as? Int) ?? 0)) }
        for (name, any) in j["lightMaterials"] as? [String: [String: Any]] ?? [:] {
            let m = any
            func c(_ p: String, _ s: String) -> float4 {
                float4(f(m[p + "R"]), f(m[p + "G"]), f(m[p + "B"]), 1) * f(m[p + s])
            }
            var g = LightMaterialGPU()
            g.dMin = c("diffuseMin", "Scale"); g.dMin.w = f(m["diffuseMinA"])
            g.dMax = c("diffuseMax", "Scale"); g.dMax.w = f(m["diffuseMaxA"])
            g.sMin = c("specularMin", "Scale"); g.sMax = c("specularMax", "Scale")
            g.eMin = c("envmapMin", "Scale"); g.eMax = c("envmapMax", "Scale")
            g.p = float4(f(m["specularPower"]), f(m["envmapPower"]), f(m["metallicScale"]), 0)
            materials[name] = g
        }
        if let attribs = j["attribs"] as? [String: Any], let looks = attribs["visuallook"] as? [String: [String: Any]],
           let look = looks["default"] {
            func curve(_ k: String) -> LookCurve? {
                guard let a = look[k] as? [Double], a.count >= 16 else { return nil }
                return LookCurve(y: float4(Float(a[1]), Float(a[5]), Float(a[9]), Float(a[13])))
            }
            if let t = look["ColourBloomTint"] as? [Double], t.count >= 3 { bloomTint = float3(Float(t[0]), Float(t[1]), Float(t[2])) }
            bloomIntensity = f(look["ColourBloomIntensity"])
            blackBloomIntensity = f(look["BlackBloomIntensity"])
            desaturation = f(look["Desaturation"])
            if let c = curve("ColourBloomCurve") { bloomCurve = c }
            if let c = curve("BlackBloomCurve") { blackBloomCurve = c }
        }
        if let suns = j["suns"] as? [[String: Any]], let s = suns.first(where: { ($0["name"] as? String) == "MIDDAY" }) ?? suns.first {
            if let p = s["position"] as? [Double], p.count == 3 { sunPosition = float3(Float(p[0]), Float(p[1]), Float(p[2])) }
            for l in s["layers"] as? [[String: Any]] ?? [] {
                let size = f(l["size"]), col = (l["colour"] as? [Int]) ?? [0, 0, 0, 0]
                guard size > 0, col.count == 4 else { continue }
                sunLayers.append((l["texture"] as? Int ?? 0, size, float4(Float(col[0]), Float(col[1]), Float(col[2]), Float(col[3])) / 128, f(l["intensity"])))
            }
        }
    }

    func material(_ name: String?) -> LightMaterialGPU? { name.flatMap { materials[$0] } }

    func textureURL(_ name: String) -> URL { root.appendingPathComponent("\(name).png") }
}

extension FXData {
    /// Material de luz de un tramo de coche: la pintura toma el del preset (Car.dress lo pone en `light`) o `paintFallback`
    /// (tráfico: TRAFFIC); el resto, el de su tira (extras.luz).
    func carMaterial(_ d: DrawRange, paintFallback: String = "METPAINTSILVER") -> LightMaterialGPU {
        if d.role == "pintura" {
            var m = material(d.light) ?? material(paintFallback) ?? .neutral
            m.p.w = 1   // el alfa de la piel es el brillo (GLOSS ×2) [D: CompositeSkin]
            return m
        }
        if d.role == "cristal", let m = material(d.light) ?? material("HEADLIGHTGLASS") { return m }
        return material(d.light) ?? .neutral
    }
}
