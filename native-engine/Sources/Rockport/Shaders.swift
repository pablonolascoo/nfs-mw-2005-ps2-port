// Shaders Metal (MSL). Se compilan al arrancar con device.makeLibrary(source:): así `swift build` no necesita
// la herramienta `metal` de Xcode ni recursos empaquetados. Tarda ~50 ms.
// El prólogo común (FrameUniforms, niebla, codificación a espacio PS2 y sombreado de coche) está en SceneShading.swift.
// La escena se escribe **codificada** (espacio de pantalla, como el GS del PS2): las mezclas ocurren en gamma (doc 20 §1).
let shaderSource = scenePreludeMSL + """

struct DrawUniforms {
    float4x4 model;
    float4   color;       // baseColorFactor (o pintura)
    float4   params;      // x = alphaCutoff (solo recorte), y = textura propia (sombra del coche), z = -, w = 1 si el alfa es brillo
    LightMat lm;          // coches: material de luz del juego
};

// Recorte de los garajes sin carga (Garage/GarageRender.swift `CutoutUniforms`): hueco de la puerta y volumen interior
// del edificio. Lo que cae dentro de una de las dos cajas no se dibuja.
struct Cutout { float4x4 a; float4x4 b; float4 on; float4x4 c; };
static bool inCutout(constant Cutout& C, float3 w) {
    if (C.on.x < 0.5) return false;
    float3 p = (C.a * float4(w, 1)).xyz;
    if (all(abs(p) < 1.0)) return true;
    p = (C.b * float4(w, 1)).xyz;
    if (all(abs(p) < 1.0)) return true;
    if (C.on.y < 0.5) return false;
    p = (C.c * float4(w, 1)).xyz;           // suelo bajo el hueco de la puerta (lo cubre el interior)
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

// Opaco: textura (sRGB → lineal al muestrear) × color de vértice (luz horneada del juego).
fragment float4 fs_opaque(VOut in [[stage_in]], constant FrameUniforms& F [[buffer(1)]],
                          texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]], constant Cutout& C [[buffer(3)]]) {
    if (inCutout(C, in.world)) discard_fragment();
    float4 t = tex.sample(s, in.uv);
    return float4(sceneRGB(F, t.rgb * in.color.rgb, in.world), 1);
}

// Recorte alfa (vallas, árboles, rejas): pasa si alfa > alphaCutoff del material (0x28/255 en el juego, `_alphaRef`).
fragment float4 fs_mask(VOut in [[stage_in]], constant FrameUniforms& F [[buffer(1)]], constant DrawUniforms& D [[buffer(2)]],
                        texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]], constant Cutout& C [[buffer(3)]]) {
    if (inCutout(C, in.world)) discard_fragment();
    float4 t = tex.sample(s, in.uv);
    if (t.a <= D.params.x) discard_fragment();
    return float4(sceneRGB(F, t.rgb * in.color.rgb, in.world), 1);
}

// Sombras horneadas (SHD_*): capa semitransparente sobre el suelo, sin escribir profundidad. Mezcla en gamma como el GS:
// con alfa 0,5 la calle queda a la mitad en pantalla (en lineal quedaba a 0,73).
fragment float4 fs_shadow(VOut in [[stage_in]], constant FrameUniforms& F [[buffer(1)]],
                          texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]], constant Cutout& C [[buffer(3)]]) {
    if (inCutout(C, in.world)) discard_fragment();
    float4 t = tex.sample(s, in.uv);
    float a = t.a * (1 - fogFactor(F, in.world));
    return float4(ps2Encode(t.rgb * in.color.rgb), a);
}

// Mezcla normal ("mezcla"/"recorte_mezcla": carteles, pintadas, suciedad): alfa = textura × vértice, sin escribir profundidad.
fragment float4 fs_decal(VOut in [[stage_in]], constant FrameUniforms& F [[buffer(1)]],
                         texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]], constant Cutout& C [[buffer(3)]]) {
    if (inCutout(C, in.world)) discard_fragment();
    float4 t = tex.sample(s, in.uv);
    float a = t.a * in.color.a;
    if (a < 0.01) discard_fragment();
    return float4(sceneRGB(F, t.rgb * in.color.rgb, in.world), a);
}

// Aditivo (luces, brillos, rayos): Cs·As sumado en gamma, As = alfa de textura × alfa de vértice; se apaga con la niebla.
fragment float4 fs_additive(VOut in [[stage_in]], constant FrameUniforms& F [[buffer(1)]],
                            texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]], constant Cutout& C [[buffer(3)]]) {
    if (inCutout(C, in.world)) discard_fragment();
    float4 t = tex.sample(s, in.uv);
    float k = t.a * saturate(in.color.a) * (1 - fogFactor(F, in.world));
    return float4(ps2Encode(t.rgb * in.color.rgb) * k, 1);
}

// Agua del mapa (ANM_WATERA_*): en el juego son 14 texturas animadas; aquí se desplaza la UV con el tiempo.
fragment float4 fs_water(VOut in [[stage_in]], constant FrameUniforms& F [[buffer(1)]],
                         texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]], constant Cutout& C [[buffer(3)]]) {
    if (inCutout(C, in.world)) discard_fragment();
    float time = F.camPos.w;
    float4 t = tex.sample(s, in.uv + float2(time * 0.03, time * 0.017));
    float a = min(in.color.a * 1.4, 1.0);
    return float4(sceneRGB(F, t.rgb * in.color.rgb, in.world), a);
}

// Coche: material de luz del juego + mapa de entorno (SceneShading.swift `carShade`).
fragment float4 fs_car(VOut in [[stage_in]], constant FrameUniforms& F [[buffer(1)]], constant DrawUniforms& D [[buffer(2)]],
                       texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]],
                       texture2d<float> env [[texture(1)]], sampler es [[sampler(1)]]) {
    float4 t = tex.sample(s, in.uv);
    float4 base = t * in.color;
    if (D.params.x > 0 && base.a <= D.params.x) discard_fragment();   // recorte (discos de freno, rejillas)
    float gloss = 1;
    if (D.params.w > 0.5) { gloss = t.a; base.a = in.color.a; }       // piel: alfa = brillo (GLOSS), no transparencia
    float4 c = carShade(F, D.lm, base, gloss, normalize(in.normal), in.world, env, es);
    return float4(sceneRGB(F, c.rgb, in.world), saturate(c.a));
}

// Sombra del coche: textura CARSHADOW del disco (o mancha propia si falta) con el alfa de la vista (env.z) [D: DrawAmbientShadow].
fragment float4 fs_blob(VOut in [[stage_in]], constant FrameUniforms& F [[buffer(1)]], constant DrawUniforms& D [[buffer(2)]],
                        texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
    float a;
    if (D.params.y > 0.5) {
        a = tex.sample(s, in.uv).a;
    } else {
        float2 q = abs(in.uv * 2.0 - 1.0);
        float r = pow(pow(q.x, 4.0) + pow(q.y, 4.0), 0.25);   // rectángulo redondeado
        a = (1.0 - smoothstep(0.80, 1.0, r)) * 0.7;
    }
    return float4(0, 0, 0, saturate(a * F.env.z * D.color.a));
}

// Capas del sol (SunChunkInfo MIDDAY: SUNCENTER, SUNHALO): suma en gamma, tapada por la escena (prueba de profundidad).
fragment float4 fs_sunlayer(VOut in [[stage_in]], constant DrawUniforms& D [[buffer(2)]],
                            texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
    float4 t = tex.sample(s, in.uv);
    float a = t.a * D.color.a;
    return float4(saturate(ps2Encode(t.rgb) * D.color.rgb) * a, 1);
}

// ---------- Cielo ----------
struct SkyOut { float4 pos [[position]]; float2 ndc; };

vertex SkyOut vs_fullscreen(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2) * 2.0 - 1.0;
    SkyOut o; o.pos = float4(p, 0, 1); o.ndc = p; return o;
}

// Cielo del juego [V: texturas de GLOBAL\\DYNTEX.BIN; I: reparto]: degradado SKY_MIDDAY_A_GRADIENT_A por elevación, banda de nubes
// SKY_MIDDAY_A_CLOUDS_A (alfa) alrededor del horizonte y casquete SKY_MIDDAY_A_CAP_A arriba; las nubes se mueven despacio
// (MoveClouds). Sin texturas: el degradado de siempre. S.x = 1 si hay texturas.
fragment float4 fs_sky(SkyOut in [[stage_in]], constant FrameUniforms& F [[buffer(1)]], constant float4& S [[buffer(2)]],
                       texture2d<float> grad [[texture(0)]], texture2d<float> clouds [[texture(1)]], texture2d<float> cap [[texture(2)]],
                       sampler s [[sampler(0)]]) {
    float4 a = F.invViewProj * float4(in.ndc, 1, 1);
    float4 b = F.invViewProj * float4(in.ndc, 0.0001, 1);
    float3 dir = normalize(b.xyz / b.w - a.xyz / a.w);
    float h = dir.z;
    float3 c;
    if (S.x > 0.5) {
        float elev = asin(clamp(h, -1.0, 1.0));                       // rad
        float e = saturate(elev / (0.5 * M_PI_F));
        c = grad.sample(s, float2(0.5, 1.0 - sqrt(e) * 0.98)).rgb;    // v = 0 cénit, 1 horizonte
        float az = atan2(dir.y, dir.x) * (0.5 / M_PI_F) + 0.5;
        float vb = 1.0 - saturate(elev / 0.62);                        // banda de nubes: del horizonte a ~35°
        if (vb > 0 && vb < 1) {
            float4 cl = clouds.sample(s, float2(az * 2.0 + F.camPos.w * 0.0004, vb));
            c = mix(c, cl.rgb, cl.a * smoothstep(0.0, 0.15, 1.0 - vb));
        }
        if (h > 0.35) {
            float2 uv = dir.xy / (1.0 + h) * 0.9 + 0.5;
            float4 cp = cap.sample(s, uv + float2(F.camPos.w * 0.0002, 0));
            c = mix(c, cp.rgb, cp.a * smoothstep(0.35, 0.6, h));
        }
        c = mix(c, F.skyHaze.rgb, smoothstep(0.02, -0.05, h));        // bajo el horizonte: bruma
    } else {
        c = mix(F.skyHorizon.rgb, F.skyHaze.rgb, smoothstep(0.25, -0.02, h));
        c = mix(c, F.skyZenith.rgb, smoothstep(0.05, 0.7, h));
    }
    return float4(ps2Encode(c), 1);
}

// ---------- Mar: plano a z = -0,2 con ondulación (hipótesis [H] del visor: el juego pinta un plano de mar) ----------
fragment float4 fs_sea(VOut in [[stage_in]], constant FrameUniforms& F [[buffer(1)]]) {
    float time = F.camPos.w;
    // Suma de ondas (no producto: el producto dibuja un damero visible desde el aire); se apagan con la distancia.
    float2 p = in.world.xy;
    float w = (sin(p.x * 0.05 + time * 0.8) + sin(p.y * 0.043 - time * 0.6) + 0.5 * sin((p.x + p.y) * 0.11 + time * 1.3)) / 2.5;
    w *= 1.0 - saturate(distance(in.world, F.camPos.xyz) / 1500.0);
    float3 c = mix(float3(0.0159, 0.0395, 0.0497), float3(0.0423, 0.1022, 0.1221), w * 0.3 + 0.5);
    return float4(sceneRGB(F, c, in.world), 0.92);
}

// ---------- Tratamiento visual (bloom de color y «black bloom», VisualTreatment.cpp + visuallook) ----------
struct PostUniforms {
    float2 uvScale;   // parte usada del objetivo de escena (resolución dinámica)
    float  strength;  // Config.ps2GradeStrength
    float  look;      // fuerza del tratamiento visual (0 = sin bloom)
    float4 bloomTint;     // rgb = ColourBloomTint × ColourBloomIntensity
    float4 bloomCurve;    // y de los 4 puntos de ColourBloomCurve
    float4 blackCurve;    // y de BlackBloomCurve
    float4 misc;          // x BlackBloomIntensity, y Desaturation, z texel u, w texel v (bloom)
    float4 tint;          // tinte de pantalla de la zona (rgb / luminancia), a = fuerza (0 = el ámbar fijo de siempre)
};

static float bez(float4 y, float t) {   // GetValueFromSpline [D]
    t = saturate(t);
    float m = 1.0 - t;
    return m * m * m * y.x + 3.0 * t * m * m * y.y + 3.0 * t * t * m * y.z + t * t * t * y.w;
}
static float luma(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }

// Reducción a 1/4 con paso de brillo: peso = curva de ColourBloomCurve sobre la luminancia (en gamma).
fragment float4 fs_bright(SkyOut in [[stage_in]], constant PostUniforms& P [[buffer(0)]],
                          texture2d<float> scene [[texture(0)]], sampler s [[sampler(0)]]) {
    float2 uv = float2(in.ndc.x * 0.5 + 0.5, 0.5 - in.ndc.y * 0.5) * P.uvScale;
    float2 px = 1.0 / float2(scene.get_width(), scene.get_height());
    float3 c = 0;
    for (int j = -1; j <= 1; j += 2) for (int i = -1; i <= 1; i += 2) {
        float2 q = min(uv + float2(i, j) * px, P.uvScale - px * 0.5);
        c += saturate(scene.sample(s, q).rgb);
    }
    c *= 0.25;
    float w = saturate(bez(P.bloomCurve, luma(c)));
    return float4(c * w, luma(c));
}

// Desenfoque separable (9 muestras, pesos gaussianos), en la textura de 1/4.
fragment float4 fs_blur(SkyOut in [[stage_in]], constant float4& dir [[buffer(0)]],
                        texture2d<float> src [[texture(0)]], sampler s [[sampler(0)]]) {
    float2 uv = float2(in.ndc.x * 0.5 + 0.5, 0.5 - in.ndc.y * 0.5);
    const float w[5] = { 0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216 };
    float4 c = src.sample(s, uv) * w[0];
    for (int i = 1; i < 5; i++) {
        c += src.sample(s, uv + dir.xy * float(i)) * w[i];
        c += src.sample(s, uv - dir.xy * float(i)) * w[i];
    }
    return c;
}

// ---------- Pasada final: escalado a pantalla + tratamiento visual del juego + tono PS2 ----------
fragment float4 fs_post(SkyOut in [[stage_in]], constant PostUniforms& P [[buffer(0)]],
                        texture2d<float> scene [[texture(0)]], sampler s [[sampler(0)]],
                        texture2d<float> bloom [[texture(1)]]) {
    float2 suv = float2(in.ndc.x * 0.5 + 0.5, 0.5 - in.ndc.y * 0.5);
    float2 uv = suv * P.uvScale;
    uv = min(uv, P.uvScale - 0.5 / float2(scene.get_width(), scene.get_height()));   // no leer fuera de la zona dibujada
    float3 c = saturate(scene.sample(s, uv).rgb);    // la escena ya está en espacio de pantalla (doc 20 §1)
    if (P.look > 0) {
        float4 b = bloom.sample(s, suv);
        // «Black bloom» [I]: curva en S de BlackBloomCurve sobre la luminancia local (difusa) → más contraste en las sombras.
        float lb = max(b.a, 1e-3);
        float ratio = clamp(bez(P.blackCurve, lb) / lb, 0.0, 1.6);
        c *= mix(1.0, ratio, P.misc.x * P.look);
        // Bloom de color: lo brillante, desenfocado y teñido (ColourBloomTint × intensidad), en suma de pantalla [I].
        float3 add = b.rgb * P.bloomTint.rgb * P.look;
        c = 1.0 - (1.0 - c) * (1.0 - saturate(add));
        // Desaturación del visuallook.
        c = mix(c, float3(luma(c)), P.misc.y * P.look);
    }
    float k = P.strength;
    if (k > 0) {
        // 1. Negros levantados con un toque cálido (el PS2 nunca daba negro puro por la salida analógica).
        float3 lift = float3(0.045, 0.036, 0.018) * k;
        c = lift + c * (1.0 - lift);
        // 2. Tinte amarillo/ámbar en medios tonos y luces (no en sombras).
        float l = dot(c, float3(0.299, 0.587, 0.114));
        float w = smoothstep(0.12, 0.80, l);
        // Con tinte de zona (ParameterMaps «Screen Tint Midday» [V]) ese color manda; si no, el ámbar fijo de antes [I].
        float3 amber = P.tint.a > 0 ? mix(float3(1.0), P.tint.rgb, P.tint.a) : float3(1.070, 1.030, 0.860);
        c *= mix(float3(1.0), amber, saturate(k * w));
        // 3. Saturación algo más baja en general, pero conservando los cálidos.
        float l2 = dot(c, float3(0.299, 0.587, 0.114));
        float warm = saturate((c.r - c.b) * 2.0);
        float sat = 1.0 - 0.10 * k + 0.08 * k * warm;
        c = mix(float3(l2), c, sat);
    }
    return float4(saturate(c), 1);
}
"""
