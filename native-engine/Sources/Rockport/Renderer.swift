// Renderizador Metal. Pasadas por fotograma:
//   1. Escena a una textura rgba16Float a resolución dinámica, **codificada en espacio de pantalla como el GS del PS2** (las
//      mezclas ocurren en gamma, doc 20 §1): cielo del juego → opacos → recorte alfa → coche (material de luz + reflejo) →
//      sol → mar → sombras horneadas y sombra del coche (CARSHADOW) → mezcla → aditivos → agua → cristales del coche.
//   2. Tratamiento visual: reducción a 1/4 con paso de brillo (ColourBloomCurve) y desenfoque separable.
//   3. Pasada final a pantalla: escalado bilineal + bloom de color, «black bloom» y desaturación del visuallook + tono PS2.
// Profundidad invertida (1 cerca, 0 lejos) con plano lejano infinito, en memoria "memoryless" (no sale de la GPU).
import Foundation
import Metal
import MetalKit
import simd

// FrameUniforms está en SceneShading.swift (compartido con los shaders de la IA y de los garajes).

struct DrawUniforms {
    var model: float4x4
    var color: float4
    var params: float4
    var lm = LightMaterialGPU.neutral
}

struct PostUniforms {
    var uvScale: float2
    var strength: Float
    var look: Float = 1
    var bloomTint = float4.zero
    var bloomCurve = float4.zero
    var blackCurve = float4.zero
    var misc = float4.zero
}

/// Lo que hay que dibujar en un fotograma.
struct SceneFrame {
    var view: float4x4
    var proj: float4x4
    var camPos: float3
    var time: Float
    var meshes: [GPUMesh]
    var car: (mesh: GPUMesh, parts: [float4x4])?
    /// Sombra de contacto: matriz del cuadrado unidad (-1…1) bajo el coche.
    var carShadow: float4x4?
    /// Otros coches con malla completa y física del juego (rivales de carrera, Race/): se dibujan como el del jugador.
    var extraCars: [(mesh: GPUMesh, parts: [float4x4], shadow: float4x4?)] = []
    /// Luz de la vista (doc 20): calle por defecto; los garajes ponen la suya (SceneLighting.frontEnd).
    var lighting: SceneLighting = .world
}

final class Renderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let textures: TextureCache
    let outputFormat: MTLPixelFormat
    private var pipelines: [String: MTLRenderPipelineState] = [:]
    private var depthWrite: MTLDepthStencilState!
    private var depthRead: MTLDepthStencilState!
    private var depthOff: MTLDepthStencilState!
    private var samplers: [MTLSamplerState] = []   // índice = wrap (bit 0 repite U, bit 1 repite V)
    private var postSampler: MTLSamplerState!
    private var seaBuffer: MTLBuffer!
    private var seaIndex: MTLBuffer!
    private var quadBuffer: MTLBuffer!
    private var sceneColor: MTLTexture?
    private var sceneDepth: MTLTexture?
    private var bloomA: MTLTexture?, bloomB: MTLTexture?
    private var envSampler: MTLSamplerState!
    var gradeStrength: Float = Config.ps2GradeStrength
    /// Fuerza del tratamiento visual del juego (bloom de color, black bloom, desaturación). 0 = apagado. `ROCKPORT_LOOK`.
    var lookStrength: Float = Float(ProcessInfo.processInfo.environment["ROCKPORT_LOOK"] ?? "") ?? Config.visualLookStrength
    /// Fuerza de los reflejos de los coches (Config.envStrength; depuración: `ROCKPORT_ENV`).
    var envScale: Float = Float(ProcessInfo.processInfo.environment["ROCKPORT_ENV"] ?? "") ?? Config.envStrength
    /// Datos de luz y efectos (fx/, doc 20). Lo pone el motor al cargar los datos.
    var fx: FXData?
    private var fxTextureCache: [String: MTLTexture?] = [:]
    /// Textura de fx/ (mapas de entorno, cielo, sol, sombra del coche); nil si los datos son anteriores al formato 8.
    func fxTexture(_ name: String) -> MTLTexture? {
        if let t = fxTextureCache[name] { return t }
        guard let fx, fx.loaded, FileManager.default.fileExists(atPath: fx.textureURL(name).path) else { fxTextureCache[name] = .some(nil); return nil }
        let t = textures.texture(url: fx.textureURL(name), alpha: true)
        if t != nil { fxTextureCache[name] = t }   // la subida es asíncrona: hasta que llegue se vuelve a pedir
        return t
    }
    /// Capas extra (tráfico y policía de AIRender.swift, HUD de persecución): se dibujan dentro de las pasadas.
    var overlays: [RenderOverlay] = []

    // Estadísticas del último fotograma
    private(set) var lastDrawCalls = 0
    private(set) var lastTriangles = 0

    init(device: MTLDevice, queue: MTLCommandQueue, textures: TextureCache, outputFormat: MTLPixelFormat) throws {
        self.device = device
        self.queue = queue
        self.textures = textures
        self.outputFormat = outputFormat
        let lib = try device.makeLibrary(source: shaderSource, options: nil)

        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3; vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float2; vd.attributes[1].offset = 12; vd.attributes[1].bufferIndex = 0
        vd.attributes[2].format = .half4; vd.attributes[2].offset = 20; vd.attributes[2].bufferIndex = 0
        vd.attributes[3].format = .char4Normalized; vd.attributes[3].offset = 28; vd.attributes[3].bufferIndex = 0
        vd.layouts[0].stride = MemoryLayout<Vertex>.stride
        precondition(MemoryLayout<Vertex>.stride == 32, "Vertex debe medir 32 bytes")

        enum Blend { case none, alpha, add }
        func make(_ name: String, vs: String, fs: String, blend: Blend, color: MTLPixelFormat = .rgba16Float, depth: Bool = true, vertex: Bool = true) throws {
            let d = MTLRenderPipelineDescriptor()
            d.label = name
            d.vertexFunction = lib.makeFunction(name: vs)
            d.fragmentFunction = lib.makeFunction(name: fs)
            if vertex { d.vertexDescriptor = vd }
            d.colorAttachments[0].pixelFormat = color
            if depth { d.depthAttachmentPixelFormat = .depth32Float }
            let c = d.colorAttachments[0]!
            switch blend {
            case .none: break
            case .alpha:
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .sourceAlpha; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            case .add:
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .one
                c.sourceAlphaBlendFactor = .zero; c.destinationAlphaBlendFactor = .one
            }
            pipelines[name] = try device.makeRenderPipelineState(descriptor: d)
        }
        try make("sky", vs: "vs_fullscreen", fs: "fs_sky", blend: .none, vertex: false)
        try make("opaque", vs: "vs_world", fs: "fs_opaque", blend: .none)
        try make("mask", vs: "vs_world", fs: "fs_mask", blend: .none)
        try make("car", vs: "vs_world", fs: "fs_car", blend: .none)
        try make("carBlend", vs: "vs_world", fs: "fs_car", blend: .alpha)
        try make("sea", vs: "vs_world", fs: "fs_sea", blend: .alpha)
        try make("shadow", vs: "vs_world", fs: "fs_shadow", blend: .alpha)
        try make("decal", vs: "vs_world", fs: "fs_decal", blend: .alpha)
        try make("blob", vs: "vs_world", fs: "fs_blob", blend: .alpha)
        try make("sunlayer", vs: "vs_world", fs: "fs_sunlayer", blend: .add)
        try make("bright", vs: "vs_fullscreen", fs: "fs_bright", blend: .none, depth: false, vertex: false)
        try make("blur", vs: "vs_fullscreen", fs: "fs_blur", blend: .none, depth: false, vertex: false)
        try make("water", vs: "vs_world", fs: "fs_water", blend: .alpha)
        try make("additive", vs: "vs_world", fs: "fs_additive", blend: .add)
        try make("post", vs: "vs_fullscreen", fs: "fs_post", blend: .none, color: outputFormat, depth: false, vertex: false)

        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .greaterEqual; ds.isDepthWriteEnabled = true
        depthWrite = device.makeDepthStencilState(descriptor: ds)
        ds.isDepthWriteEnabled = false
        depthRead = device.makeDepthStencilState(descriptor: ds)
        ds.depthCompareFunction = .always
        depthOff = device.makeDepthStencilState(descriptor: ds)

        for w in 0..<4 {
            let sd = MTLSamplerDescriptor()
            sd.minFilter = .linear; sd.magFilter = .linear; sd.mipFilter = .linear
            sd.sAddressMode = w & 1 != 0 ? .repeat : .clampToEdge
            sd.tAddressMode = w & 2 != 0 ? .repeat : .clampToEdge
            sd.maxAnisotropy = 8
            samplers.append(device.makeSamplerState(descriptor: sd)!)
        }
        let ps = MTLSamplerDescriptor()
        ps.minFilter = .linear; ps.magFilter = .linear
        ps.sAddressMode = .clampToEdge; ps.tAddressMode = .clampToEdge
        postSampler = device.makeSamplerState(descriptor: ps)
        let es = MTLSamplerDescriptor()
        es.minFilter = .linear; es.magFilter = .linear; es.mipFilter = .linear
        es.sAddressMode = .repeat; es.tAddressMode = .clampToEdge
        envSampler = device.makeSamplerState(descriptor: es)

        // Mar: cuadrado de 40 km centrado en la ciudad, a z = -0,2 (como el visor)
        let c = float2(2200, 1800), h: Float = 20000
        let white = half(1), up = packNormal(float3(0, 0, 1))
        var sea = [float2(-h, -h), float2(h, -h), float2(h, h), float2(-h, h)].map {
            Vertex(px: c.x + $0.x, py: c.y + $0.y, pz: -0.2, u: 0, v: 0, r: white, g: white, b: white, a: white, normal: up)
        }
        seaBuffer = device.makeBuffer(bytes: &sea, length: MemoryLayout<Vertex>.stride * 4, options: .storageModeShared)
        var idx: [UInt32] = [0, 1, 2, 0, 2, 3]
        seaIndex = device.makeBuffer(bytes: &idx, length: 24, options: .storageModeShared)
        var quad = [float2(-1, -1), float2(1, -1), float2(1, 1), float2(-1, 1)].map {
            Vertex(px: $0.x, py: $0.y, pz: 0, u: $0.x * 0.5 + 0.5, v: $0.y * 0.5 + 0.5, r: white, g: white, b: white, a: white, normal: up)
        }
        quadBuffer = device.makeBuffer(bytes: &quad, length: MemoryLayout<Vertex>.stride * 4, options: .storageModeShared)
    }

    /// Texturas de escena por tamaño de destino (varias pantallas de distinto tamaño: Multiplayer/MultiDisplay.swift).
    private var targetCache: [SIMD2<Int>: (MTLTexture, MTLTexture)] = [:]

    /// Asegura texturas de escena del tamaño máximo (la resolución dinámica usa una parte con el viewport).
    private func ensureTargets(width: Int, height: Int) {
        if let s = sceneColor, s.width == width, s.height == height { return }
        let bd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: max(16, width / 4), height: max(16, height / 4), mipmapped: false)
        bd.usage = [.renderTarget, .shaderRead]; bd.storageMode = .private
        bloomA = device.makeTexture(descriptor: bd); bloomB = device.makeTexture(descriptor: bd)
        if let c = targetCache[SIMD2(width, height)] { sceneColor = c.0; sceneDepth = c.1; return }
        let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        cd.usage = [.renderTarget, .shaderRead]; cd.storageMode = .private
        sceneColor = device.makeTexture(descriptor: cd)
        sceneColor?.label = "escena HDR"
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        dd.usage = .renderTarget; dd.storageMode = .memoryless
        sceneDepth = device.makeTexture(descriptor: dd)
        if let c = sceneColor, let d = sceneDepth {
            if targetCache.count >= 4 { targetCache.removeAll() }
            targetCache[SIMD2(width, height)] = (c, d)
        }
    }

    /// Codifica el fotograma completo en `cb`, escribiendo el resultado final en `target`.
    /// `scale` = fracción de la resolución de `target` a la que se dibuja la escena.
    func encode(_ cb: MTLCommandBuffer, frame: SceneFrame, target: MTLTexture, scale: Float) {
        encode(cb, views: [RenderView(frame: frame, rect: RenderRect(x: 0, y: 0, w: 1, h: 1))], target: target, scale: scale)
    }

    /// Varias vistas en el mismo `target` (pantalla partida, Multiplayer/): cada una con su cámara, su recorte por frustum y su
    /// rectángulo (fracción del destino). Todas se dibujan en la misma textura HDR a `scale` y una sola pasada final aplica el
    /// tono PS2 a todo. Con una vista a pantalla completa es exactamente el camino de siempre.
    func encode(_ cb: MTLCommandBuffer, views: [RenderView], target: MTLTexture, scale: Float) {
        let W = target.width, H = target.height
        ensureTargets(width: W, height: H)
        guard let sceneColor, let sceneDepth, !views.isEmpty else { return }
        let rw = max(64, min(W, Int(Float(W) * scale))), rh = max(64, min(H, Int(Float(H) * scale)))

        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = sceneColor
        rp.colorAttachments[0].loadAction = views.count == 1 ? .dontCare : .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rp.colorAttachments[0].storeAction = .store
        rp.depthAttachment.texture = sceneDepth
        rp.depthAttachment.loadAction = .clear
        rp.depthAttachment.clearDepth = 0
        rp.depthAttachment.storeAction = .dontCare
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.label = views.count == 1 ? "escena" : "escena ×\(views.count)"
        enc.setCullMode(.none)       // los materiales del juego son de doble cara
        var draws = 0, tris = 0
        for v in views {
            // Rectángulo de la vista en la textura de escena (a resolución dinámica), en píxeles enteros
            let x0 = Int((Float(rw) * v.rect.x).rounded()), y0 = Int((Float(rh) * v.rect.y).rounded())
            let x1 = Int((Float(rw) * (v.rect.x + v.rect.w)).rounded()), y1 = Int((Float(rh) * (v.rect.y + v.rect.h)).rounded())
            guard x1 - x0 >= 8, y1 - y0 >= 8 else { continue }
            enc.setViewport(MTLViewport(originX: Double(x0), originY: Double(y0), width: Double(x1 - x0), height: Double(y1 - y0), znear: 0, zfar: 1))
            enc.setScissorRect(MTLScissorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
            let r = encodeScene(enc, frame: v.frame)
            draws += r.draws; tris += r.tris
        }
        enc.endEncoding()
        lastDrawCalls = draws; lastTriangles = tris

        let fx = self.fx
        var P = PostUniforms(uvScale: float2(Float(rw) / Float(W), Float(rh) / Float(H)), strength: gradeStrength)
        if let fx, let a = bloomA, let b = bloomB, lookStrength > 0 {
            P.look = lookStrength
            P.bloomTint = float4(fx.bloomTint * fx.bloomIntensity * Config.bloomGain, 1)
            P.bloomCurve = fx.bloomCurve.y; P.blackCurve = fx.blackBloomCurve.y
            P.misc = float4(fx.blackBloomIntensity, fx.desaturation * Config.desaturationScale, 0, 0)
            // Tratamiento visual: brillo a 1/4 → desenfoque horizontal → vertical
            func pass(_ dst: MTLTexture, _ name: String, _ body: (MTLRenderCommandEncoder) -> Void) {
                let d = MTLRenderPassDescriptor()
                d.colorAttachments[0].texture = dst; d.colorAttachments[0].loadAction = .dontCare; d.colorAttachments[0].storeAction = .store
                guard let e = cb.makeRenderCommandEncoder(descriptor: d) else { return }
                e.label = name
                body(e)
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                e.endEncoding()
            }
            pass(a, "bloom: brillo") { e in
                e.setRenderPipelineState(self.pipelines["bright"]!)
                e.setFragmentBytes(&P, length: MemoryLayout<PostUniforms>.stride, index: 0)
                e.setFragmentTexture(sceneColor, index: 0); e.setFragmentSamplerState(self.postSampler, index: 0)
            }
            for (src, dst, dir) in [(a, b, float4(1.5 / Float(a.width), 0, 0, 0)), (b, a, float4(0, 1.5 / Float(a.height), 0, 0))] {
                pass(dst, "bloom: desenfoque") { e in
                    var d = dir
                    e.setRenderPipelineState(self.pipelines["blur"]!)
                    e.setFragmentBytes(&d, length: 16, index: 0)
                    e.setFragmentTexture(src, index: 0); e.setFragmentSamplerState(self.postSampler, index: 0)
                }
            }
        } else { P.look = 0 }

        // Pasada final: escala a pantalla + tratamiento visual + tono PS2
        let pp = MTLRenderPassDescriptor()
        pp.colorAttachments[0].texture = target
        pp.colorAttachments[0].loadAction = .dontCare
        pp.colorAttachments[0].storeAction = .store
        guard let post = cb.makeRenderCommandEncoder(descriptor: pp) else { return }
        post.label = "tono PS2"
        post.setRenderPipelineState(pipelines["post"]!)
        post.setFragmentBytes(&P, length: MemoryLayout<PostUniforms>.stride, index: 0)
        post.setFragmentTexture(sceneColor, index: 0)
        post.setFragmentTexture(bloomA ?? sceneColor, index: 1)
        post.setFragmentSamplerState(postSampler, index: 0)
        post.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        post.endEncoding()
        for o in overlays { o.encodeScreen(cb, target: target) }   // HUD sobre la imagen final
    }

    /// Todas las pasadas de escena de una vista (el viewport y el recorte ya están puestos).
    private func encodeScene(_ enc: MTLRenderCommandEncoder, frame: SceneFrame) -> (draws: Int, tris: Int) {
        let viewProj = frame.proj * frame.view
        let L = frame.lighting
        let sunPos = fx?.sunPosition ?? float3(5300, -3550, 3000)
        let sunDir = simd_normalize(sunPos - frame.camPos)
        var lights = L.lights
        if L.useSun { lights.insert((sunDir, srgbToLinear(L.sunColor) * Config.sunIntensityPS2), at: 0) }
        while lights.count < 3 { lights.append((float3(0, 0, 1), .zero)) }
        let envTex = fxTexture(L.envMap)
        let fogC = L.fogColor.map { srgbToLinear($0) } ?? srgbToLinear(Config.skyHorizon)
        var F = FrameUniforms(viewProj: viewProj, invViewProj: viewProj.inverse,
                              camPos: float4(frame.camPos, frame.time),
                              fog: L.fog,
                              fogColor: float4(fogC, 1),
                              skyHorizon: float4(srgbToLinear(Config.skyHorizon), 1),
                              skyHaze: float4(srgbToLinear(Config.skyHaze), 1),
                              skyZenith: float4(srgbToLinear(Config.skyZenith), 1),
                              sunDir: float4(sunDir, L.useSun ? 1 : 0),
                              lightSky: float4(L.ambientSky, 0),
                              lightGround: float4(L.ambientGround, 0),
                              lightSun: .zero)
        F.view = frame.view
        F.lightDir0 = float4(lights[0].dir, 0); F.lightDir1 = float4(lights[1].dir, 0); F.lightDir2 = float4(lights[2].dir, 0)
        F.lightCol0 = float4(lights[0].color, 0); F.lightCol1 = float4(lights[1].color, 0); F.lightCol2 = float4(lights[2].color, 0)
        F.env = float4(envTex == nil ? 0 : L.envMode, L.envStrength * envScale, L.shadowAlpha, L.frontEnd ? 1 : 0)
        F.fogHeight = L.fogHeight
        let frustum = Frustum(viewProj)
        let visible = frame.meshes.filter { frustum.intersects($0.bounds) }
        enc.setVertexBytes(&F, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        enc.setFragmentBytes(&F, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        var cut = GarageCutout.uniforms   // garajes sin carga: recorte del edificio (Shaders.swift `Cutout`)
        enc.setFragmentBytes(&cut, length: MemoryLayout<CutoutUniforms>.stride, index: 3)
        var boundWrap = 3
        enc.setFragmentSamplerState(samplers[3], index: 0)

        var draws = 0, tris = 0
        // Cielo del juego (texturas de DYNTEX.BIN) o el degradado si faltan
        enc.setRenderPipelineState(pipelines["sky"]!)
        enc.setDepthStencilState(depthOff)
        let grad = fxTexture("SKY_MIDDAY_A_GRADIENT_A"), clouds = fxTexture("SKY_MIDDAY_A_CLOUDS_A"), cap = fxTexture("SKY_MIDDAY_A_CAP_A")
        var S = float4(grad != nil && clouds != nil && cap != nil && L.sky ? 1 : 0, 0, 0, 0)
        enc.setFragmentBytes(&S, length: 16, index: 2)
        enc.setFragmentTexture(grad ?? textures.white, index: 0)
        enc.setFragmentTexture(clouds ?? textures.white, index: 1)
        enc.setFragmentTexture(cap ?? textures.white, index: 2)
        enc.setFragmentSamplerState(samplers[1], index: 0)   // repetir en U (acimut), recortar en V
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.setFragmentSamplerState(samplers[3], index: 0)

        func drawMeshes(_ meshes: [GPUMesh], kinds: Set<MaterialKind>, model: (Int) -> float4x4 = { _ in .identity },
                        color: (DrawRange) -> float4 = { $0.color }, car: Bool = false, paintFallback: String = "METPAINTSILVER") {
            for m in meshes {
                var bound = false
                for d in m.draws where d.visible && kinds.contains(d.kind) {
                    if !bound { enc.setVertexBuffer(m.vertexBuffer, offset: 0, index: 0); bound = true }
                    var U = DrawUniforms(model: model(d.part), color: color(d), params: float4(d.kind == .mask ? d.cutoff : 0, 0, 0, 0))
                    if car {
                        U.lm = fx?.carMaterial(d, paintFallback: paintFallback) ?? .neutral
                        U.params.w = U.lm.p.w
                    }
                    enc.setVertexBytes(&U, length: MemoryLayout<DrawUniforms>.stride, index: 2)
                    enc.setFragmentBytes(&U, length: MemoryLayout<DrawUniforms>.stride, index: 2)
                    enc.setFragmentTexture(d.texture ?? textures.white, index: 0)
                    if d.wrap != boundWrap { boundWrap = d.wrap; enc.setFragmentSamplerState(samplers[d.wrap & 3], index: 0) }
                    enc.drawIndexedPrimitives(type: .triangle, indexCount: d.indexCount, indexType: .uint32,
                                              indexBuffer: m.indexBuffer, indexBufferOffset: d.indexStart * 4)
                    draws += 1; tris += d.indexCount / 3
                }
            }
        }
        func bindEnv() {
            enc.setFragmentTexture(envTex ?? textures.white, index: 1)
            enc.setFragmentSamplerState(envSampler, index: 1)
        }

        // Opacos y recorte alfa (escriben profundidad)
        enc.setDepthStencilState(depthWrite)
        enc.setRenderPipelineState(pipelines["opaque"]!)
        drawMeshes(visible, kinds: [.opaque])
        enc.setRenderPipelineState(pipelines["mask"]!)
        drawMeshes(visible, kinds: [.mask])

        // Coche (opaco): material de luz del juego + reflejo
        bindEnv()
        if let car = frame.car {
            enc.setRenderPipelineState(pipelines["car"]!)
            drawMeshes([car.mesh], kinds: [.opaque, .mask], model: { car.parts[$0] }, car: true)
        }
        if !frame.extraCars.isEmpty {
            enc.setRenderPipelineState(pipelines["car"]!)
            for c in frame.extraCars where frustum.intersects(AABB(min: float3(c.parts[0].columns.3.x, c.parts[0].columns.3.y, c.parts[0].columns.3.z) - 4,
                                                                   max: float3(c.parts[0].columns.3.x, c.parts[0].columns.3.y, c.parts[0].columns.3.z) + 4)) {
                drawMeshes([c.mesh], kinds: [.opaque, .mask], model: { c.parts[$0] }, car: true)
            }
        }
        for o in overlays { o.encodeOpaque(enc, frame: frame) }   // coches de la IA (instanciados), interiores de garajes
        enc.setVertexBytes(&F, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        enc.setFragmentBytes(&F, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        enc.setFragmentSamplerState(samplers[boundWrap & 3], index: 0)

        // Transparentes: no escriben profundidad
        enc.setDepthStencilState(depthRead)
        // Sol (SunChunkInfo MIDDAY): capas con textura (centro y halo) en su posición, tapadas por la escena
        if L.useSun, let fx, fx.loaded, sunDir.z > -0.05 {
            let v = frame.view
            let right = float3(v.columns.0.x, v.columns.1.x, v.columns.2.x), up = float3(v.columns.0.y, v.columns.1.y, v.columns.2.y)
            let dist = simd_distance(sunPos, frame.camPos), D: Float = 4000
            enc.setRenderPipelineState(pipelines["sunlayer"]!)
            enc.setVertexBuffer(quadBuffer, offset: 0, index: 0)
            for layer in fx.sunLayers {
                guard let tex = fxTexture(layer.texture == 0 ? "SUNCENTER" : layer.texture == 1 ? "SUNHALO" : "") else { continue }
                let r = layer.size * 0.5 * D / dist
                let c = frame.camPos + sunDir * D
                let m = float4x4(columns: (float4(right * r, 0), float4(up * r, 0), float4(simd_cross(right, up), 0), float4(c, 1)))
                var U = DrawUniforms(model: m, color: float4(layer.color.x, layer.color.y, layer.color.z, layer.color.w) * float4(1, 1, 1, layer.intensity), params: .zero)
                enc.setVertexBytes(&U, length: MemoryLayout<DrawUniforms>.stride, index: 2)
                enc.setFragmentBytes(&U, length: MemoryLayout<DrawUniforms>.stride, index: 2)
                enc.setFragmentTexture(tex, index: 0)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: 6, indexType: .uint32, indexBuffer: seaIndex, indexBufferOffset: 0)
                draws += 1
            }
        }
        enc.setRenderPipelineState(pipelines["sea"]!)
        var seaU = DrawUniforms(model: .identity, color: float4(1, 1, 1, 1), params: .zero)
        enc.setVertexBuffer(seaBuffer, offset: 0, index: 0)
        enc.setVertexBytes(&seaU, length: MemoryLayout<DrawUniforms>.stride, index: 2)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: 6, indexType: .uint32, indexBuffer: seaIndex, indexBufferOffset: 0)
        draws += 1

        enc.setRenderPipelineState(pipelines["shadow"]!)
        enc.setDepthBias(1, slopeScale: 2, clamp: 0.01)   // Z invertida: sesgo positivo = hacia la cámara
        drawMeshes(visible, kinds: [.shadow])
        // Sombra de cada coche: CARSHADOW [V: GLOBALB.BUN] en la caja del coche, alargada hacia el lado contrario al sol
        // (SunScale = (1 − sol.z)·0,5 m, DrawAmbientShadow [D]); en el frontend sin sol y a alfa 255.
        let shadowTex = fxTexture("CARSHADOW")
        enc.setFragmentSamplerState(samplers[0], index: 0); boundWrap = 0
        for m in [frame.carShadow] + frame.extraCars.map(\.shadow) + overlays.flatMap(\.shadowQuads).map(Optional.some) {
            guard let m else { continue }
            enc.setRenderPipelineState(pipelines["blob"]!)
            var q = m
            if L.useSun {
                let ax = float3(m.columns.0.x, m.columns.0.y, m.columns.0.z), ay = float3(m.columns.1.x, m.columns.1.y, m.columns.1.z)
                let hx = max(simd_length(ax), 0.01), hy = max(simd_length(ay), 0.01)
                let sunScale = (1 - sunDir.z) * 0.5
                let adj = float2(-simd_dot(sunDir, ax / hx), -simd_dot(sunDir, ay / hy)) * sunScale / float2(hx, hy)   // en unidades del cuadrado
                q = m * float4x4(translation: float3(adj.x, adj.y, 0)) * float4x4(scale: float3(1 + abs(adj.x) * 0.5, 1 + abs(adj.y) * 0.5, 1))
            }
            var U = DrawUniforms(model: q, color: float4(1, 1, 1, 1), params: float4(0, shadowTex == nil ? 0 : 1, 0, 0))
            enc.setVertexBuffer(quadBuffer, offset: 0, index: 0)
            enc.setVertexBytes(&U, length: MemoryLayout<DrawUniforms>.stride, index: 2)
            enc.setFragmentBytes(&U, length: MemoryLayout<DrawUniforms>.stride, index: 2)
            enc.setFragmentTexture(shadowTex ?? textures.white, index: 0)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: 6, indexType: .uint32, indexBuffer: seaIndex, indexBufferOffset: 0)
            draws += 1
        }
        enc.setDepthBias(0, slopeScale: 0, clamp: 0)
        // Mismo orden que el visor: sombras y mezcla (1) → aditivos (2) → agua (3)
        enc.setRenderPipelineState(pipelines["decal"]!)
        drawMeshes(visible, kinds: [.blend])
        enc.setRenderPipelineState(pipelines["additive"]!)
        drawMeshes(visible, kinds: [.additive])
        enc.setRenderPipelineState(pipelines["water"]!)
        drawMeshes(visible, kinds: [.water])
        bindEnv()
        if let car = frame.car {
            enc.setRenderPipelineState(pipelines["carBlend"]!)
            drawMeshes([car.mesh], kinds: [.blend, .shadow, .additive, .water], model: { car.parts[$0] }, car: true)
        }
        if !frame.extraCars.isEmpty {
            enc.setRenderPipelineState(pipelines["carBlend"]!)
            for c in frame.extraCars where simd_distance(frame.camPos, float3(c.parts[0].columns.3.x, c.parts[0].columns.3.y, c.parts[0].columns.3.z)) < 400 {
                drawMeshes([c.mesh], kinds: [.blend, .shadow, .additive, .water], model: { c.parts[$0] }, car: true)
            }
        }
        for o in overlays { o.encodeTransparent(enc, frame: frame); draws += o.drawCalls }
        return (draws, tris)
    }
}

/// Rectángulo de una vista como fracción del destino (0…1, origen arriba a la izquierda, como el viewport de Metal).
struct RenderRect: Equatable {
    var x: Float, y: Float, w: Float, h: Float
    static let full = RenderRect(x: 0, y: 0, w: 1, h: 1)
    var aspectFactor: Float { w / max(h, 1e-4) }
}

/// Una vista de la escena: lo que se ve (cámara y objetos) y dónde va en el destino.
struct RenderView {
    var frame: SceneFrame
    var rect: RenderRect
}
