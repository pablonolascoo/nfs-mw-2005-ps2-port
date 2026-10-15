// Dibujo de los rompibles (formato 11: ya no van dentro de las casillas cercanas). Mismo sombreado que el escenario
// (shaderSource: fs_opaque / fs_mask / fs_decal) con un vertex shader instanciado: una llamada por modelo y material.
// Los modelos (smackables/<SÓLIDO>.glb) se cargan en un hilo de fondo la primera vez que hacen falta.
import Foundation
import Metal
import simd

private let smackVertexMSL = """

vertex VOut vs_smack(VertexIn in [[stage_in]], uint iid [[instance_id]], constant FrameUniforms& F [[buffer(1)]],
                     constant DrawUniforms& D [[buffer(2)]], const device float4x4* mats [[buffer(3)]]) {
    float4x4 M = mats[iid];
    VOut o;
    float4 w = M * float4(in.pos, 1);
    o.pos = F.viewProj * w;
    o.world = w.xyz;
    o.normal = normalize((M * float4(in.normal.xyz, 0)).xyz + 1e-6);
    o.uv = in.uv;
    o.color = float4(in.color) * D.color;
    return o;
}
"""


final class SmackableRenderer: RenderOverlay {
    let device: MTLDevice
    let data: GameData
    let textures: TextureCache
    unowned let field: SmackableField
    private var pOpaque: MTLRenderPipelineState!, pMask: MTLRenderPipelineState!, pBlend: MTLRenderPipelineState!
    private var depthWrite: MTLDepthStencilState!, depthRead: MTLDepthStencilState!
    private var samplers: [MTLSamplerState] = []
    private var ring: [MTLBuffer] = []
    private var ringIndex = 0
    private static let maxInst = 4096
    private var meshes: [String: GPUMesh] = [:]
    private var loading = Set<String>(), failed = Set<String>()
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "rockport.smackables", qos: .utility, attributes: .concurrent)
    private var batches: [(mesh: GPUMesh, start: Int, count: Int)] = []
    private(set) var drawCalls = 0
    private(set) var drawnObjects = 0
    var radius: Float = 260

    init(device: MTLDevice, data: GameData, textures: TextureCache, field: SmackableField, outputFormat: MTLPixelFormat) throws {
        self.device = device; self.data = data; self.textures = textures; self.field = field
        let lib = try device.makeLibrary(source: shaderSource + smackVertexMSL, options: nil)
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3; vd.attributes[0].offset = 0
        vd.attributes[1].format = .float2; vd.attributes[1].offset = 12
        vd.attributes[2].format = .half4; vd.attributes[2].offset = 20
        vd.attributes[3].format = .char4Normalized; vd.attributes[3].offset = 28
        vd.layouts[0].stride = MemoryLayout<Vertex>.stride
        func make(_ fs: String, blend: Bool) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "vs_smack"); d.fragmentFunction = lib.makeFunction(name: fs)
            d.vertexDescriptor = vd
            d.colorAttachments[0].pixelFormat = .rgba16Float
            d.depthAttachmentPixelFormat = .depth32Float
            if blend {
                let c = d.colorAttachments[0]!
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .sourceAlpha; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        pOpaque = try make("fs_opaque", blend: false)
        pMask = try make("fs_mask", blend: false)
        pBlend = try make("fs_decal", blend: true)
        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .greaterEqual; ds.isDepthWriteEnabled = true
        depthWrite = device.makeDepthStencilState(descriptor: ds)
        ds.isDepthWriteEnabled = false
        depthRead = device.makeDepthStencilState(descriptor: ds)
        for w in 0..<4 {
            let sd = MTLSamplerDescriptor()
            sd.minFilter = .linear; sd.magFilter = .linear; sd.mipFilter = .linear; sd.maxAnisotropy = 8
            sd.sAddressMode = w & 1 != 0 ? .repeat : .clampToEdge; sd.tAddressMode = w & 2 != 0 ? .repeat : .clampToEdge
            samplers.append(device.makeSamplerState(descriptor: sd)!)
        }
        for _ in 0..<16 { ring.append(device.makeBuffer(length: SmackableRenderer.maxInst * 64, options: .storageModeShared)!) }
    }

    private func mesh(_ glb: String) -> GPUMesh? {
        lock.lock(); defer { lock.unlock() }
        if let m = meshes[glb] { return m }
        if loading.contains(glb) || failed.contains(glb) { return nil }
        loading.insert(glb)
        queue.async { [self] in
            let url = data.url(glb)
            var m: GPUMesh? = nil
            if let f = try? GLB.load(url) { m = GPUMesh.build(device: device, file: f, textures: textures, keyPrefix: url.path) }
            lock.lock(); loading.remove(glb)
            if let m { meshes[glb] = m } else { failed.insert(glb) }
            lock.unlock()
        }
        return nil
    }

    /// Precarga los modelos de los rompibles cercanos (pruebas: sin esperar a que aparezcan).
    func preload(around p: float3, radius r: Float) {
        var list: [Smackable] = []
        field.visible(around: p, radius: r, into: &list)
        for s in list { if let g = s.def.glb { _ = mesh(g) } }
    }
    var idle: Bool { lock.lock(); defer { lock.unlock() }; return loading.isEmpty }

    private func prepare(frame: SceneFrame) {
        ringIndex = (ringIndex + 1) % ring.count
        let mats = ring[ringIndex].contents().bindMemory(to: float4x4.self, capacity: SmackableRenderer.maxInst)
        batches.removeAll(keepingCapacity: true)
        guard field.enabled else { return }
        var list: [Smackable] = []
        field.visible(around: frame.camPos, radius: radius, into: &list)
        let frustum = Frustum(frame.proj * frame.view)
        var byGlb: [String: [float4x4]] = [:]
        var order: [String] = []
        for s in list {
            guard let g = s.def.glb else { continue }
            let c = s.pos
            let r = s.boundRadius + 1
            guard frustum.intersects(AABB(min: c - float3(r, r, r), max: c + float3(r, r, r * 2))) else { continue }
            if byGlb[g] == nil { order.append(g) }
            byGlb[g, default: []].append(s.renderMatrix)
        }
        var n = 0
        drawnObjects = 0
        for g in order {
            guard let m = mesh(g), let ms = byGlb[g] else { continue }
            let start = n
            for x in ms where n < SmackableRenderer.maxInst { mats[n] = x; n += 1 }
            if n > start { batches.append((m, start, n - start)); drawnObjects += n - start }
        }
    }

    private func draw(_ enc: MTLRenderCommandEncoder, kinds: Set<MaterialKind>, pipeline: (MaterialKind) -> MTLRenderPipelineState) {
        let buf = ring[ringIndex]
        var current: MTLRenderPipelineState?
        for b in batches {
            enc.setVertexBuffer(b.mesh.vertexBuffer, offset: 0, index: 0)
            enc.setVertexBuffer(buf, offset: b.start * 64, index: 3)
            for d in b.mesh.draws where d.visible && kinds.contains(d.kind) {
                let p = pipeline(d.kind)
                if p !== current { enc.setRenderPipelineState(p); current = p }
                var U = DrawUniforms(model: .identity, color: d.color, params: float4(d.kind == .mask ? d.cutoff : 0, 0, 0, 0))
                enc.setVertexBytes(&U, length: MemoryLayout<DrawUniforms>.stride, index: 2)
                enc.setFragmentBytes(&U, length: MemoryLayout<DrawUniforms>.stride, index: 2)
                enc.setFragmentTexture(d.texture ?? textures.white, index: 0)
                enc.setFragmentSamplerState(samplers[d.wrap & 3], index: 0)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: d.indexCount, indexType: .uint32, indexBuffer: b.mesh.indexBuffer,
                                          indexBufferOffset: d.indexStart * 4, instanceCount: b.count)
                drawCalls += 1
            }
        }
    }

    func encodeOpaque(_ enc: MTLRenderCommandEncoder, frame: SceneFrame) {
        drawCalls = 0
        prepare(frame: frame)
        guard !batches.isEmpty else { return }
        enc.setDepthStencilState(depthWrite)
        draw(enc, kinds: [.opaque, .mask]) { $0 == .mask ? self.pMask : self.pOpaque }
    }

    func encodeTransparent(_ enc: MTLRenderCommandEncoder, frame: SceneFrame) {
        guard !batches.isEmpty else { return }
        enc.setDepthStencilState(depthRead)
        draw(enc, kinds: [.blend, .shadow]) { _ in self.pBlend }
    }

    func encodeScreen(_ cb: MTLCommandBuffer, target: MTLTexture) {}
}
