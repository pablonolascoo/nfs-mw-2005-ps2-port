// Shaders Metal (MSL). Se compilan al arrancar con device.makeLibrary(source:): así `swift build` no necesita
// la herramienta `metal` de Xcode ni recursos empaquetados. Tarda ~50 ms.
let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct FrameUniforms {
    float4x4 viewProj;
    float4x4 invViewProj;
    float4   camPos;      // xyz cámara, w tiempo (s)
    float4   fog;         // inicio, fin, -, -
    float4   fogColor;    // lineal
    float4   skyHorizon;  // lineal
    float4   skyHaze;
    float4   skyZenith;
    float4   sunDir;      // xyz hacia el sol
    float4   lightSky;    // luces del coche: cielo y suelo de la hemisférica, sol (lineal × intensidad)
    float4   lightGround;
    float4   lightSun;
};

struct DrawUniforms {
    float4x4 model;
    float4   color;       // baseColorFactor (o pintura)
    float4   params;      // x = alphaCutoff (solo recorte), y = metalicidad, z = rugosidad (coche), w = -
};

// Recorte de los garajes sin carga (Garage/GarageRender.swift `CutoutUniforms`): hueco de la puerta y volumen interior
// del edificio. Lo que cae dentro de una de las dos cajas no se dibuja.
struct Cutout { float4x4 a; float4x4 b; float4 on; };
static bool inCutout(constant Cutout& C, float3 w) {
    if (C.on.x < 0.5) return false;
    float3 p = (C.a * float4(w, 1)).xyz;
    if (all(abs(p) < 1.0)) return true;
    p = (C.b * float4(w, 1)).xyz;
    return all(abs(p) < 1.0);
}

struct VertexIn {
    float3 pos    [[attribute(0)]];
    float2 uv     [[attribute(1)]];
    half4  color  [[attribute(2)]];
    float4 normal [[attribute(3)]];
};

struct VOut {
    float4 pos [[position]];
    float3 world;
    float3 normal;
    float2 uv;
    float4 color;
};

vertex VOut vs_world(VertexIn in [[stage_in]], constant FrameUniforms& F [[buffer(1)]], constant DrawUniforms& D [[buffer(2)]]) {
    VOut o;
    float4 w = D.model * float4(in.pos, 1);
    o.pos = F.viewProj * w;
    o.world = w.xyz;
    o.normal = normalize((D.model * float4(in.normal.xyz, 0)).xyz + 1e-6);
    o.uv = in.uv;
    o.color = float4(in.color) * D.color;
    return o;
}

static float fogFactor(constant FrameUniforms& F, float3 world) {
    float d = distance(world, F.camPos.xyz);
    return saturate((d - F.fog.x) / (F.fog.y - F.fog.x));
}

static float3 applyFog(constant FrameUniforms& F, float3 c, float3 world) {
    return mix(c, F.fogColor.rgb, fogFactor(F, world));
}

// Opaco: textura (sRGB → lineal al muestrear) × color de vértice (luz horneada del juego).
fragment float4 fs_opaque(VOut in [[stage_in]], constant FrameUniforms& F [[buffer(1)]],
                          texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]], constant Cutout& C [[buffer(3)]]) {
    if (inCutout(C, in.world)) discard_fragment();
    float4 t = tex.sample(s, in.uv);
    return float4(applyFog(F, t.rgb * in.color.rgb, in.world), 1);
}

// Recorte alfa (vallas, árboles, rejas): pasa si alfa > alphaCutoff del material (0x28/255 en el juego, `_alphaRef`).
fragment float4 fs_mask(VOut in [[stage_in]], constant FrameUniforms& F [[buffer(1)]], constant DrawUniforms& D [[buffer(2)]],
                        texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]], constant Cutout& C [[buffer(3)]]) {
    if (inCutout(C, in.world)) discard_fragment();
    float4 t = tex.sample(s, in.uv);
    if (t.a <= D.params.x) discard_fragment();
    return float4(applyFog(F, t.rgb * in.color.rgb, in.world), 1);
}

// Sombras horneadas (SHD_*): capa semitransparente sobre el suelo, sin escribir profundidad.
fragment float4 fs_shadow(VOut in [[stage_in]], constant FrameUniforms& F [[buffer(1)]],
                          texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]], constant Cutout& C [[buffer(3)]]) {
    if (inCutout(C, in.world)) discard_fragment();
    float4 t = tex.sample(s, in.uv);
    float a = t.a * (1 - fogFactor(F, in.world));
    return float4(t.rgb * in.color.rgb, a);
}

// Mezcla normal ("mezcla"/"recorte_mezcla": carteles, pintadas, suciedad): alfa = textura × vértice, sin escribir profundidad.
fragment float4 fs_decal(VOut in [[stage_in]], constant FrameUniforms& F [[buffer(1)]],
                         texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]], constant Cutout& C [[buffer(3)]]) {
    if (inCutout(C, in.world)) discard_fragment();
    float4 t = tex.sample(s, in.uv);
    float a = t.a * in.color.a;
    if (a < 0.01) discard_fragment();
    return float4(applyFog(F, t.rgb * in.color.rgb, in.world), a);
}

// Aditivo (luces, brillos): se suma y se apaga con la niebla.
fragment float4 fs_additive(VOut in [[stage_in]], constant FrameUniforms& F [[buffer(1)]],
                            texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]], constant Cutout& C [[buffer(3)]]) {
    if (inCutout(C, in.world)) discard_fragment();
    float4 t = tex.sample(s, in.uv);
    float k = t.a * (1 - fogFactor(F, in.world));
    return float4(t.rgb * in.color.rgb * k, 1);
}

// Agua del mapa (ANM_WATERA_*): en el juego son 14 texturas animadas; aquí se desplaza la UV con el tiempo.
fragment float4 fs_water(VOut in [[stage_in]], constant FrameUniforms& F [[buffer(1)]],
                         texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]], constant Cutout& C [[buffer(3)]]) {
    if (inCutout(C, in.world)) discard_fragment();
    float time = F.camPos.w;
    float4 t = tex.sample(s, in.uv + float2(time * 0.03, time * 0.017));
    float a = min(in.color.a * 1.4, 1.0);
    return float4(applyFog(F, t.rgb * in.color.rgb, in.world), a);
}

// Coche: el mismo modelo de luz que el visor (MeshStandardMaterial de three.js sin mapa de entorno):
// difusa Lambert con luz hemisférica + sol, y especular GGX del sol (Smith correlado, Fresnel de Schlick).
// Los coches del juego no traen luz horneada; el juego usa mapas de entorno (pendiente).
fragment float4 fs_car(VOut in [[stage_in]], constant FrameUniforms& F [[buffer(1)]], constant DrawUniforms& D [[buffer(2)]],
                       texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
    float4 t = tex.sample(s, in.uv);
    float4 base = t * in.color;
    if (D.params.x > 0 && base.a <= D.params.x) discard_fragment();   // recorte (discos de freno, rejillas)
    float metal = D.params.y, rough = max(D.params.z, 0.0525);
    float3 n = normalize(in.normal);
    float3 v = normalize(F.camPos.xyz - in.world);
    if (dot(n, v) < 0) n = -n;                                         // doble cara
    float3 L = normalize(F.sunDir.xyz);
    float3 albedo = base.rgb * (1.0 - metal);
    float3 f0 = mix(float3(0.04), base.rgb, metal);
    float3 hemi = mix(F.lightGround.rgb, F.lightSky.rgb, 0.5 * n.z + 0.5);
    float NL = saturate(dot(n, L)), NV = saturate(dot(n, v));
    float3 h = normalize(L + v);
    float NH = saturate(dot(n, h)), VH = saturate(dot(v, h));
    float a2 = rough * rough; a2 *= a2;
    float fr = exp2((-5.55473 * VH - 6.98316) * VH);
    float3 Fs = f0 * (1.0 - fr) + fr;
    float gv = NL * sqrt(a2 + (1.0 - a2) * NV * NV), gl = NV * sqrt(a2 + (1.0 - a2) * NL * NL);
    float vis = 0.5 / max(gv + gl, 1e-6);
    float dd = NH * NH * (a2 - 1.0) + 1.0;
    float Dg = a2 / (M_PI_F * dd * dd);
    float3 c = albedo * (hemi + F.lightSun.rgb * NL) / M_PI_F + F.lightSun.rgb * NL * Fs * (vis * Dg);
    return float4(applyFog(F, c, in.world), base.a);
}

// Sombra de contacto del coche: mancha oscura bajo la carrocería (el juego también usa una sombra simple).
fragment float4 fs_blob(VOut in [[stage_in]]) {
    float2 q = abs(in.uv * 2.0 - 1.0);
    float r = pow(pow(q.x, 4.0) + pow(q.y, 4.0), 0.25);   // rectángulo redondeado
    float a = (1.0 - smoothstep(0.80, 1.0, r)) * 0.55;
    return float4(0, 0, 0, a);
}

// ---------- Cielo: degradado por altura de la dirección de vista (como el visor web) ----------
struct SkyOut { float4 pos [[position]]; float2 ndc; };

vertex SkyOut vs_fullscreen(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2) * 2.0 - 1.0;
    SkyOut o; o.pos = float4(p, 0, 1); o.ndc = p; return o;
}

fragment float4 fs_sky(SkyOut in [[stage_in]], constant FrameUniforms& F [[buffer(1)]]) {
    float4 a = F.invViewProj * float4(in.ndc, 1, 1);
    float4 b = F.invViewProj * float4(in.ndc, 0.0001, 1);
    float3 dir = normalize(b.xyz / b.w - a.xyz / a.w);
    float h = dir.z;
    float3 c = mix(F.skyHorizon.rgb, F.skyHaze.rgb, smoothstep(0.25, -0.02, h));
    c = mix(c, F.skyZenith.rgb, smoothstep(0.05, 0.7, h));
    return float4(c, 1);
}

// ---------- Mar: plano a z = -0,2 con ondulación (hipótesis [H] del visor: el juego pinta un plano de mar) ----------
fragment float4 fs_sea(VOut in [[stage_in]], constant FrameUniforms& F [[buffer(1)]]) {
    float time = F.camPos.w;
    // Suma de ondas (no producto: el producto dibuja un damero visible desde el aire); se apagan con la distancia.
    float2 p = in.world.xy;
    float w = (sin(p.x * 0.05 + time * 0.8) + sin(p.y * 0.043 - time * 0.6) + 0.5 * sin((p.x + p.y) * 0.11 + time * 1.3)) / 2.5;
    w *= 1.0 - saturate(distance(in.world, F.camPos.xyz) / 1500.0);
    float3 c = mix(float3(0.0159, 0.0395, 0.0497), float3(0.0423, 0.1022, 0.1221), w * 0.3 + 0.5);
    return float4(applyFog(F, c, in.world), 0.92);
}

// ---------- Pasada final: escalado a pantalla + tono PS2 ----------
struct PostUniforms {
    float2 uvScale;   // parte usada del objetivo de escena (resolución dinámica)
    float  strength;  // Config.ps2GradeStrength
    float  pad;
};

static float3 linearToSRGB(float3 c) {
    c = saturate(c);
    return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
}

fragment float4 fs_post(SkyOut in [[stage_in]], constant PostUniforms& P [[buffer(0)]],
                        texture2d<float> scene [[texture(0)]], sampler s [[sampler(0)]]) {
    float2 uv = float2(in.ndc.x * 0.5 + 0.5, 0.5 - in.ndc.y * 0.5) * P.uvScale;
    uv = min(uv, P.uvScale - 0.5 / float2(scene.get_width(), scene.get_height()));   // no leer fuera de la zona dibujada
    float3 c = linearToSRGB(scene.sample(s, uv).rgb);   // el tono se aplica en espacio de pantalla (gamma)
    float k = P.strength;
    if (k > 0) {
        // 1. Negros levantados con un toque cálido (el PS2 nunca daba negro puro por la salida analógica).
        float3 lift = float3(0.045, 0.036, 0.018) * k;
        c = lift + c * (1.0 - lift);
        // 2. Tinte amarillo/ámbar en medios tonos y luces (no en sombras).
        float l = dot(c, float3(0.299, 0.587, 0.114));
        float w = smoothstep(0.12, 0.80, l);
        c *= mix(float3(1.0), float3(1.070, 1.030, 0.860), saturate(k * w));
        // 3. Saturación algo más baja en general, pero conservando los cálidos.
        float l2 = dot(c, float3(0.299, 0.587, 0.114));
        float warm = saturate((c.r - c.b) * 2.0);
        float sat = 1.0 - 0.10 * k + 0.08 * k * warm;
        c = mix(float3(l2), c, sat);
    }
    return float4(saturate(c), 1);
}
"""
