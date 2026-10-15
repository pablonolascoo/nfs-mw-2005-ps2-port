// Dibujo de los garajes: interiores del frontend (FRONTEND\PLATFORMS\*.BIN → interiors/*.glb), la persiana enrollable
// y el recorte del edificio del mundo.
//
// - Los interiores se dibujan como capa (RenderOverlay) dentro de las pasadas de escena, con su propia matriz de modelo,
//   un tinte (mods) y una caja de recorte: lo que cae fuera de la caja no se ve (así el interior no asoma por las
//   paredes del edificio del mundo).
// - El recorte del mundo (hueco de la puerta + volumen interior del edificio) lo hacen los shaders del mundo
//   (Shaders.swift, `Cutout`, buffer 3 del fragmento) con `GarageCutout.uniforms`.
import Foundation
import Metal
import simd

/// Uniformes del recorte del mundo. Debe coincidir con `Cutout` de Shaders.swift.
struct CutoutUniforms {
    /// Mundo → caja (−1…1): hueco de la puerta y volumen interior del edificio.
    var a: float4x4 = .identity
    var b: float4x4 = .identity
    /// x > 0,5: recorte activo.
    var on: float4 = .zero
}

/// Recorte activo del mundo (lo pone el garaje abierto; lo lee el Renderer en cada vista).
enum GarageCutout {
    static var uniforms = CutoutUniforms()
    static var active: Bool { uniforms.on.x > 0.5 }
    /// ¿Cae `p` dentro del recorte? (colisiones del edificio que se ignoran con la puerta abierta)
    static func contains(_ p: float3) -> Bool {
        guard active else { return false }
        for m in [uniforms.a, uniforms.b] {
            let l = m * float4(p, 1)
            if abs(l.x) < 1 && abs(l.y) < 1 && abs(l.z) < 1 { return true }
        }
        return false
    }
}

/// Interiores cargados (uno por nombre; se reutilizan entre garajes).
final class InteriorLibrary {
    private var cache: [String: GPUMesh?] = [:]
    private var files: [String: GLBFile] = [:]
    let device: MTLDevice, data: GameData, textures: TextureCache
    init(device: MTLDevice, data: GameData, textures: TextureCache) { self.device = device; self.data = data; self.textures = textures }

    /// CAREER_SAFEHOUSE, PLATFORMCRIB, CAR_LOT, CUSTOMIZATION_SHOP, CUSTOMIZATION_SHOP_BACKROOM.
    func mesh(_ name: String) -> GPUMesh? {
        if let m = cache[name] { return m }
        let url = data.url("interiors/\(name).glb")
        var m: GPUMesh? = nil
        if let f = try? GLB.load(url) {
            files[name] = f
            m = GPUMesh.build(device: device, file: f, textures: textures, keyPrefix: url.path)
        } else { fputs("garaje: no se pudo leer \(url.path)\n", stderr) }
        cache[name] = m
        return m
    }

    /// Fondo del frontend que no va dentro de un edificio del mundo: cúpula del cielo (…_SKY) y la caja que rodea el refugio
    /// con la vista de fuera (CRIB1_OFFICE_TEXTURE), ambos del sólido BACKDROP_CURRGEN [V: interiors/*.glb].
    static func isBackdrop(_ p: GLBPrimitive, _ f: GLBFile) -> Bool {
        guard p.nodeName == "BACKDROP_CURRGEN" else { return false }
        let n = f.materials[p.material].name.uppercased()
        return n.hasSuffix("_SKY") || n.contains("MIDDAYSKY") || n.contains("OFFICE_TEXTURE")
    }

    /// El interior para meterlo en un edificio del mundo: sin el cielo ni la caja de fondo.
    private var worldCache: [String: GPUMesh?] = [:]
    func worldMesh(_ name: String) -> GPUMesh? {
        if let m = worldCache[name] { return m }
        _ = mesh(name)
        var m: GPUMesh? = nil
        if let f = files[name] {
            let prims = f.primitives.filter { !InteriorLibrary.isBackdrop($0, f) }
            m = GPUMesh.build(device: device, file: f, textures: textures, keyPrefix: data.url("interiors/\(name).glb").path, prims: prims)
        }
        worldCache[name] = m
        return m
    }

    /// Triángulos del interior (coordenadas propias, sin el fondo) para rayos y colisión.
    func triangles(_ name: String) -> [float3] {
        _ = mesh(name)
        guard let f = files[name] else { return [] }
        var out: [float3] = []
        for p in f.primitives where (f.materials[p.material].kind == .opaque || f.materials[p.material].kind == .mask) && !InteriorLibrary.isBackdrop(p, f) {
            for i in p.indices { let v = p.vertices[Int(i)]; out.append(float3(v.px, v.py, v.pz)) }
        }
        return out
    }
}

/// Una pieza que dibuja la capa de garajes.
struct GarageDrawItem {
    var mesh: GPUMesh
    var model: float4x4
    /// Mundo → caja de recorte (−1…1); nil = sin recorte.
    var clip: float4x4?
    var tint: float3 = float3(1, 1, 1)
}

// Mismo espacio de color que la escena (SceneShading.swift): se escribe codificado y se mezcla en gamma, como el GS del PS2.
// Así los rayos de luz aditivos (CRIB1_LIGHTRAYS01/02, SFX_LIGHTRAY, CSHOP_/QRACE_/CARLOT_LIGHTRAY*) quedan como bruma suave:
// Cs (textura × vértice, saturado a 255) × As (alfa de textura × alfa de vértice) sumado en pantalla [D: GS].
private let garageShaderSource = scenePreludeMSL + """

struct GDraw { float4x4 model; float4x4 clip; float4 color; float4 params; };   // params: x corte alfa, y recorte activo
struct VertexIn { float3 pos [[attribute(0)]]; float2 uv [[attribute(1)]]; half4 color [[attribute(2)]]; float4 normal [[attribute(3)]]; };
struct VOut { float4 pos [[position]]; float3 world; float2 uv; float4 color; };

vertex VOut vs_garage(VertexIn in [[stage_in]], constant FrameUniforms& F [[buffer(1)]], constant GDraw& D [[buffer(2)]]) {
    VOut o; float4 w = D.model * float4(in.pos, 1);
    o.pos = F.viewProj * w; o.world = w.xyz; o.uv = in.uv; o.color = float4(in.color) * D.color;
    return o;
}
static void clipIt(constant GDraw& D, float3 w) {
    if (D.params.y > 0.5) { float3 l = (D.clip * float4(w, 1)).xyz; if (any(abs(l) > 1.0)) discard_fragment(); }
}
fragment float4 fs_gopaque(VOut in [[stage_in]], constant FrameUniforms& F [[buffer(1)]], constant GDraw& D [[buffer(2)]],
                           texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
    clipIt(D, in.world);
    float4 t = tex.sample(s, in.uv);
    if (D.params.x > 0 && t.a <= D.params.x) discard_fragment();
    return float4(sceneRGB(F, t.rgb * in.color.rgb, in.world), 1);
}
fragment float4 fs_gblend(VOut in [[stage_in]], constant FrameUniforms& F [[buffer(1)]], constant GDraw& D [[buffer(2)]],
                          texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
    clipIt(D, in.world);
    float4 t = tex.sample(s, in.uv);
    float a = t.a * in.color.a;
    if (a < 0.01) discard_fragment();
    return float4(sceneRGB(F, t.rgb * in.color.rgb, in.world), a);
}
fragment float4 fs_gadd(VOut in [[stage_in]], constant FrameUniforms& F [[buffer(1)]], constant GDraw& D [[buffer(2)]],
                        texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
    clipIt(D, in.world);
    float4 t = tex.sample(s, in.uv);
    float a = t.a * saturate(in.color.a) * (1.0 - fogFactor(F, in.world));
    return float4(ps2Encode(t.rgb * in.color.rgb) * a, 1);
}
"""

private struct GDraw { var model: float4x4; var clip: float4x4; var color: float4; var params: float4 }

/// Capa de dibujo de los garajes (interiores, persiana) dentro de las pasadas de escena.
final class GarageRenderer: RenderOverlay {
    let device: MTLDevice
    let textures: TextureCache
    private var pOpaque: MTLRenderPipelineState!, pBlend: MTLRenderPipelineState!, pAdd: MTLRenderPipelineState!
    private var depthWrite: MTLDepthStencilState!, depthRead: MTLDepthStencilState!
    private var samplers: [MTLSamplerState] = []
    /// Lo que se dibuja este fotograma (lo rellenan el frontend y los garajes del mundo).
    var items: [GarageDrawItem] = []
    /// Solo se dibuja si la vista lo pide (las vistas de pantalla partida no ven el escenario del frontend).
    var enabled = true
    private(set) var drawCalls = 0
    /// Depuración: ROCKPORT_GARAGE_HIDE="NOMBRE1,NOMBRE2" oculta los materiales del interior cuyo nombre contiene esos textos.
    static let debugHide: [String]? = ProcessInfo.processInfo.environment["ROCKPORT_GARAGE_HIDE"].map { $0.split(separator: ",").map(String.init) }

    init(device: MTLDevice, textures: TextureCache) throws {
        self.device = device; self.textures = textures
        let lib = try device.makeLibrary(source: garageShaderSource, options: nil)
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3; vd.attributes[0].offset = 0
        vd.attributes[1].format = .float2; vd.attributes[1].offset = 12
        vd.attributes[2].format = .half4; vd.attributes[2].offset = 20
        vd.attributes[3].format = .char4Normalized; vd.attributes[3].offset = 28
        vd.layouts[0].stride = MemoryLayout<Vertex>.stride
        func make(_ fs: String, blend: Int) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.label = "garaje " + fs
            d.vertexFunction = lib.makeFunction(name: "vs_garage"); d.fragmentFunction = lib.makeFunction(name: fs)
            d.vertexDescriptor = vd
            d.colorAttachments[0].pixelFormat = .rgba16Float
            d.depthAttachmentPixelFormat = .depth32Float
            let c = d.colorAttachments[0]!
            if blend == 1 {
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .sourceAlpha; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            } else if blend == 2 {
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .one
                c.sourceAlphaBlendFactor = .zero; c.destinationAlphaBlendFactor = .one
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        pOpaque = try make("fs_gopaque", blend: 0)
        pBlend = try make("fs_gblend", blend: 1)
        pAdd = try make("fs_gadd", blend: 2)
        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .greaterEqual; ds.isDepthWriteEnabled = true
        depthWrite = device.makeDepthStencilState(descriptor: ds)
        ds.isDepthWriteEnabled = false
        depthRead = device.makeDepthStencilState(descriptor: ds)
        for w in 0..<4 {
            let sd = MTLSamplerDescriptor()
            sd.minFilter = .linear; sd.magFilter = .linear; sd.mipFilter = .linear; sd.maxAnisotropy = 8
            sd.sAddressMode = w & 1 != 0 ? .repeat : .clampToEdge
            sd.tAddressMode = w & 2 != 0 ? .repeat : .clampToEdge
            samplers.append(device.makeSamplerState(descriptor: sd)!)
        }
    }

    private func draw(_ enc: MTLRenderCommandEncoder, kinds: Set<MaterialKind>, frame: SceneFrame) {
        let fr = Frustum(frame.proj * frame.view)
        for it in items {
            let b = it.mesh.bounds
            // Caja del interior en el mundo (8 esquinas) para el recorte por frustum
            var wb = AABB.empty
            for k in 0..<8 {
                let c = float3(k & 1 == 0 ? b.min.x : b.max.x, k & 2 == 0 ? b.min.y : b.max.y, k & 4 == 0 ? b.min.z : b.max.z)
                let w = it.model * float4(c, 1); wb.add(float3(w.x, w.y, w.z))
            }
            if !fr.intersects(wb) { continue }
            var bound = false
            for d in it.mesh.draws where d.visible && kinds.contains(d.kind) {
                if let h = GarageRenderer.debugHide, h.contains(where: { d.name.contains($0) }) { continue }
                if !bound { enc.setVertexBuffer(it.mesh.vertexBuffer, offset: 0, index: 0); bound = true }
                var U = GDraw(model: it.model, clip: it.clip ?? .identity, color: d.color * float4(it.tint, 1),
                              params: float4(d.kind == .mask ? d.cutoff : 0, it.clip == nil ? 0 : 1, 0, 0))
                enc.setVertexBytes(&U, length: MemoryLayout<GDraw>.stride, index: 2)
                enc.setFragmentBytes(&U, length: MemoryLayout<GDraw>.stride, index: 2)
                enc.setFragmentTexture(d.texture ?? textures.white, index: 0)
                enc.setFragmentSamplerState(samplers[d.wrap & 3], index: 0)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: d.indexCount, indexType: .uint32,
                                          indexBuffer: it.mesh.indexBuffer, indexBufferOffset: d.indexStart * 4)
                drawCalls += 1
            }
        }
    }

    func encodeOpaque(_ enc: MTLRenderCommandEncoder, frame: SceneFrame) {
        drawCalls = 0
        guard enabled, !items.isEmpty else { return }
        enc.setDepthStencilState(depthWrite)
        enc.setRenderPipelineState(pOpaque)
        draw(enc, kinds: [.opaque, .mask], frame: frame)
    }
    func encodeTransparent(_ enc: MTLRenderCommandEncoder, frame: SceneFrame) {
        guard enabled, !items.isEmpty else { return }
        enc.setDepthStencilState(depthRead)
        enc.setRenderPipelineState(pBlend)
        draw(enc, kinds: [.blend, .shadow, .water], frame: frame)
        enc.setRenderPipelineState(pAdd)
        draw(enc, kinds: [.additive], frame: frame)
    }
    func encodeScreen(_ cb: MTLCommandBuffer, target: MTLTexture) {}
}
