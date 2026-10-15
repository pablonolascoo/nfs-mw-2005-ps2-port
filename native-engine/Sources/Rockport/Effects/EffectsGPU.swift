// Dibujo de los efectos (EffectsSystem.swift): partículas, destellos y haces de luz, en el espacio de color del PS2 (doc 20 §2).
//  - Partículas: textura (sRGB → lineal) × color del vértice del juego (bytes/128, en gamma: (c/128)^2,2 en lineal), alfa =
//    textura × vértice. Mezcla normal en gamma (sceneRGB, con niebla) o suma Cs·As (ps2Encode × alfa) según el AlphaBlendType de
//    la textura del TPK «PARTICLE» [V]. Sin escribir profundidad.
//  - Destellos: suma Cs·As con Cs = textura × color (satura como el GS) y As el peso del destello, adelantados ZBias m.
//  - Haces de luz: suma, sin textura (degradado propio) [I].
import Foundation
import Metal
import simd

private let effectsShaderSource = scenePreludeMSL + """

struct PInst { float4 posSize; float4 colour; float4 uv; float4 misc; };
struct POut { float4 pos [[position]]; float3 world; float2 uv; float4 colour; float slice [[flat]]; };

static float2 corner(uint vid) {
    return float2((vid == 1 || vid == 2 || vid == 4) ? 1.0 : -1.0, (vid == 2 || vid == 4 || vid == 5) ? 1.0 : -1.0);
}

// PlatRotateScaleParticle + GetConstraintBasis [D]: de cara a la cámara girada mParticle.mAngle, o en un plano del mundo.
vertex POut vs_particle(uint vid [[vertex_id]], uint iid [[instance_id]], constant FrameUniforms& F [[buffer(1)]],
                        const device PInst* P [[buffer(3)]]) {
    PInst p = P[iid];
    float2 c = corner(vid);
    float ca = cos(p.misc.x), sa = sin(p.misc.x);
    float3 xb, yb;
    int mode = int(p.misc.z + 0.5);
    if (mode == 1)      { xb = float3(ca, sa, 0);  yb = float3(-sa, ca, 0); }
    else if (mode == 2) { xb = float3(ca, 0, -sa); yb = float3(sa, 0, ca); }
    else if (mode == 3) { xb = float3(0, ca, sa);  yb = float3(0, -sa, ca); }
    else {
        float3 right = float3(F.view[0].x, F.view[1].x, F.view[2].x), up = float3(F.view[0].y, F.view[1].y, F.view[2].y);
        xb = right * ca + up * sa; yb = up * ca - right * sa;
    }
    float3 w = p.posSize.xyz + (xb * c.x + yb * c.y) * p.posSize.w;
    POut o;
    o.pos = F.viewProj * float4(w, 1);
    o.world = w;
    float2 t = c * 0.5 + 0.5;
    o.uv = float2(mix(p.uv.x, p.uv.z, t.x), mix(p.uv.w, p.uv.y, t.y));
    o.colour = p.colour;
    o.slice = p.misc.y;
    return o;
}

fragment float4 fs_pblend(POut in [[stage_in]], constant FrameUniforms& F [[buffer(1)]],
                          texture2d_array<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
    float4 t = tex.sample(s, in.uv, uint(in.slice));
    float3 lin = t.rgb * pow(max(in.colour.rgb, 0.0), 2.2);
    float a = saturate(t.a * in.colour.a);
    if (a < 0.002) discard_fragment();
    return float4(sceneRGB(F, lin, in.world), a);
}

fragment float4 fs_padd(POut in [[stage_in]], constant FrameUniforms& F [[buffer(1)]],
                        texture2d_array<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
    float4 t = tex.sample(s, in.uv, uint(in.slice));
    float k = t.a * min(in.colour.a, 2.0) * (1.0 - fogFactor(F, in.world));
    return float4(ps2Encode(t.rgb * pow(max(in.colour.rgb, 0.0), 2.2)) * k, 1);
}

// ---------- Destellos ----------
struct FInst { float4 posRadius; float4 colour; float4 misc; };
struct FOut { float4 pos [[position]]; float2 uv; float3 colour; float weight; float texIndex [[flat]]; };

vertex FOut vs_eflare(uint vid [[vertex_id]], uint iid [[instance_id]], constant FrameUniforms& F [[buffer(1)]],
                      const device FInst* L [[buffer(3)]]) {
    FInst f = L[iid];
    float2 c = corner(vid);
    float3 to = F.camPos.xyz - f.posRadius.xyz;
    float d = length(to);
    float3 p = f.posRadius.xyz + to / max(d, 1e-3) * min(f.misc.x, d * 0.5);     // ZBias: hacia la cámara
    float3 right = float3(F.view[0].x, F.view[1].x, F.view[2].x), up = float3(F.view[0].y, F.view[1].y, F.view[2].y);
    float3 w = p + (right * c.x + up * c.y) * f.posRadius.w;
    FOut o;
    o.pos = F.viewProj * float4(w, 1);
    o.uv = c * float2(0.5, -0.5) + 0.5;
    o.colour = f.colour.rgb;
    o.weight = f.misc.y * (1.0 - fogFactor(F, f.posRadius.xyz));
    o.texIndex = f.colour.a;
    return o;
}

fragment float4 fs_eflare(FOut in [[stage_in]], texture2d<float> t0 [[texture(0)]], texture2d<float> t1 [[texture(1)]],
                          texture2d<float> t2 [[texture(2)]], sampler s [[sampler(0)]]) {
    float4 t = in.texIndex < 0.5 ? t0.sample(s, in.uv) : (in.texIndex < 1.5 ? t1.sample(s, in.uv) : t2.sample(s, in.uv));
    // Cs = textura × color (satura a 255 como el GS), sumado con peso As × alfa de la textura
    float3 cs = ps2Encode(t.rgb * pow(in.colour, 2.2));
    return float4(cs * t.a * in.weight, 1);
}

// ---------- Haces de luz de las ventanas ----------
struct SVert { float4 pos; float4 uvw; };   // uvw: x a lo ancho (−1…1), y a lo largo (0 ventana … 1 suelo), z intensidad
struct SOut { float4 pos [[position]]; float3 world; float3 uvw; };
vertex SOut vs_shaft(uint vid [[vertex_id]], constant FrameUniforms& F [[buffer(1)]], const device SVert* V [[buffer(3)]]) {
    SVert v = V[vid];
    SOut o; o.pos = F.viewProj * float4(v.pos.xyz, 1); o.world = v.pos.xyz; o.uvw = v.uvw.xyz; return o;
}
fragment float4 fs_shaft(SOut in [[stage_in]], constant FrameUniforms& F [[buffer(1)]], constant float4& C [[buffer(2)]]) {
    float edge = 1.0 - smoothstep(0.55, 1.0, abs(in.uvw.x));
    float along = (1.0 - in.uvw.y) * smoothstep(0.0, 0.08, in.uvw.y) * 0.8 + 0.2 * (1.0 - in.uvw.y);
    // Polvo en suspensión: bandas suaves que se mueven despacio [I]
    float dust = 0.85 + 0.15 * sin(in.world.x * 1.7 + in.world.y * 1.3 + in.world.z * 2.1 + F.camPos.w * 0.4);
    float k = edge * along * dust * in.uvw.z * C.a * (1.0 - fogFactor(F, in.world));
    return float4(ps2Encode(C.rgb) * k, 1);
}
"""

final class EffectsGPU {
    let device: MTLDevice
    private var pBlend: MTLRenderPipelineState!, pAdd: MTLRenderPipelineState!, pFlare: MTLRenderPipelineState!, pShaft: MTLRenderPipelineState!
    private var depthRead: MTLDepthStencilState!
    private var sampler: MTLSamplerState!
    private(set) var array: MTLTexture?
    /// Textura de partícula → capa del array.
    private(set) var slice: [String: Int] = [:]
    private var flareTex: [MTLTexture] = []
    private var ring: [(particles: MTLBuffer, flares: MTLBuffer, shafts: MTLBuffer)] = []
    private var ringIndex = 0
    static let maxParticles = 4096, maxFlares = 4096, maxShaftVerts = 6 * 256

    init(device: MTLDevice, queue: MTLCommandQueue, textures: TextureCache, library: EffectsLibrary) throws {
        self.device = device
        let lib = try device.makeLibrary(source: effectsShaderSource, options: nil)
        func make(_ vs: String, _ fs: String, additive: Bool) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.label = "efectos " + fs
            d.vertexFunction = lib.makeFunction(name: vs); d.fragmentFunction = lib.makeFunction(name: fs)
            d.colorAttachments[0].pixelFormat = .rgba16Float
            d.depthAttachmentPixelFormat = .depth32Float
            let c = d.colorAttachments[0]!
            c.isBlendingEnabled = true
            if additive {
                c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .one
                c.sourceAlphaBlendFactor = .zero; c.destinationAlphaBlendFactor = .one
            } else {
                c.sourceRGBBlendFactor = .sourceAlpha; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        pBlend = try make("vs_particle", "fs_pblend", additive: false)
        pAdd = try make("vs_particle", "fs_padd", additive: true)
        pFlare = try make("vs_eflare", "fs_eflare", additive: true)
        pShaft = try make("vs_shaft", "fs_shaft", additive: true)
        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .greaterEqual; ds.isDepthWriteEnabled = false
        depthRead = device.makeDepthStencilState(descriptor: ds)
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear; sd.mipFilter = .linear
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: sd)
        for _ in 0..<16 {
            ring.append((device.makeBuffer(length: EffectsGPU.maxParticles * MemoryLayout<ParticleInstance>.stride, options: .storageModeShared)!,
                         device.makeBuffer(length: EffectsGPU.maxFlares * MemoryLayout<FlareInstance>.stride, options: .storageModeShared)!,
                         device.makeBuffer(length: EffectsGPU.maxShaftVerts * 32, options: .storageModeShared)!))
        }
        buildArray(queue: queue, textures: textures, library: library)
        // Texturas de los destellos (eLightFlareTextureNameHashes[3]) [H: orden GLOW, OUTER, INNER]
        let fxRoot = library.root.appendingPathComponent("fx")
        for n in ["HEADLIGHTGLOW", "HEADLIGHTFLAREOUTER", "HEADLIGHTFLAREINNER"] {
            flareTex.append(textures.texture(url: fxRoot.appendingPathComponent("\(n).png"), alpha: true) ?? textures.white)
        }
    }

    /// Todas las texturas de partícula usadas por algún emisor, a 64×64 en un array con mipmaps.
    private func buildArray(queue: MTLCommandQueue, textures: TextureCache, library: EffectsLibrary) {
        let names = Array(Set(library.emitters.map(\.texture).filter { !$0.isEmpty })).sorted()
        var imgs: [(String, TextureCache.Image)] = []
        for n in names {
            guard let d = try? Data(contentsOf: library.particleTextureURL(n)), var img = textures.decodePNG(d) else { continue }
            TextureCache.dilate(&img)
            imgs.append((n, img))
        }
        guard !imgs.isEmpty else { return }
        let S = 64
        let td = MTLTextureDescriptor()
        td.textureType = .type2DArray; td.pixelFormat = .rgba8Unorm_srgb
        td.width = S; td.height = S; td.arrayLength = imgs.count; td.mipmapLevelCount = 7
        td.usage = [.shaderRead]; td.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: td) else { return }
        tex.label = "partículas"
        for (i, (n, img)) in imgs.enumerated() {
            var px = [UInt8](repeating: 0, count: S * S * 4)
            for y in 0..<S { for x in 0..<S {   // bilineal a 64×64
                let fx = (Float(x) + 0.5) * Float(img.width) / Float(S) - 0.5, fy = (Float(y) + 0.5) * Float(img.height) / Float(S) - 0.5
                let x0 = max(0, min(img.width - 1, Int(floor(fx)))), y0 = max(0, min(img.height - 1, Int(floor(fy))))
                let x1 = min(img.width - 1, x0 + 1), y1 = min(img.height - 1, y0 + 1)
                let tx = max(0, min(1, fx - Float(x0))), ty = max(0, min(1, fy - Float(y0)))
                for c in 0..<4 {
                    func g(_ xx: Int, _ yy: Int) -> Float { Float(img.rgba[(yy * img.width + xx) * 4 + c]) }
                    let v = (g(x0, y0) * (1 - tx) + g(x1, y0) * tx) * (1 - ty) + (g(x0, y1) * (1 - tx) + g(x1, y1) * tx) * ty
                    px[(y * S + x) * 4 + c] = UInt8(max(0, min(255, v.rounded())))
                }
            } }
            tex.replace(region: MTLRegionMake2D(0, 0, S, S), mipmapLevel: 0, slice: i, withBytes: px, bytesPerRow: S * 4, bytesPerImage: S * S * 4)
            slice[n] = i
        }
        if let cb = queue.makeCommandBuffer(), let b = cb.makeBlitCommandEncoder() {
            b.generateMipmaps(for: tex); b.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        }
        array = tex
    }

    /// Dibuja la vista: partículas (mezcla, ya ordenadas; luego aditivas), haces y destellos. Devuelve las llamadas.
    func draw(_ enc: MTLRenderCommandEncoder, blend: [ParticleInstance], add: [ParticleInstance], flares: [FlareInstance],
              shafts: (verts: [float4], colour: float4)?) -> Int {
        ringIndex = (ringIndex + 1) % ring.count
        let r = ring[ringIndex]
        var calls = 0
        enc.setDepthStencilState(depthRead)
        enc.setCullMode(.none)
        if let arr = array, !(blend.isEmpty && add.isEmpty) {
            let nb = min(blend.count, EffectsGPU.maxParticles), na = min(add.count, EffectsGPU.maxParticles - nb)
            let p = r.particles.contents().bindMemory(to: ParticleInstance.self, capacity: EffectsGPU.maxParticles)
            for i in 0..<nb { p[i] = blend[i] }
            for i in 0..<na { p[nb + i] = add[i] }
            enc.setVertexBuffer(r.particles, offset: 0, index: 3)
            enc.setFragmentTexture(arr, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            if nb > 0 { enc.setRenderPipelineState(pBlend); enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: nb); calls += 1 }
            if na > 0 {
                enc.setRenderPipelineState(pAdd)
                enc.setVertexBuffer(r.particles, offset: nb * MemoryLayout<ParticleInstance>.stride, index: 3)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: na); calls += 1
            }
        }
        if let s = shafts, !s.verts.isEmpty {
            let n = min(s.verts.count / 2, EffectsGPU.maxShaftVerts)
            let v = r.shafts.contents().bindMemory(to: float4.self, capacity: EffectsGPU.maxShaftVerts * 2)
            for i in 0..<(n * 2) { v[i] = s.verts[i] }
            var c = s.colour
            enc.setRenderPipelineState(pShaft)
            enc.setVertexBuffer(r.shafts, offset: 0, index: 3)
            enc.setFragmentBytes(&c, length: 16, index: 2)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: n); calls += 1
        }
        if !flares.isEmpty {
            let n = min(flares.count, EffectsGPU.maxFlares)
            let f = r.flares.contents().bindMemory(to: FlareInstance.self, capacity: EffectsGPU.maxFlares)
            for i in 0..<n { f[i] = flares[i] }
            enc.setRenderPipelineState(pFlare)
            enc.setVertexBuffer(r.flares, offset: 0, index: 3)
            for (i, t) in flareTex.enumerated() { enc.setFragmentTexture(t, index: i) }
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: n); calls += 1
        }
        return calls
    }
}
