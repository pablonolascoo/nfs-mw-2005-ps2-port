// Dibujo de los coches de la IA con instancias: una llamada por (modelo, material) sin importar cuántos coches haya.
// Matrices de las 9 piezas por coche en un búfer por fotograma (anillo de 16: una entrada por vista de pantalla partida y fotograma en vuelo).
// Extras: pilotos de freno encendidos al frenar, destellos de la barra de luces de policía (rojo/azul alternos y blancos,
// fórmula de CarRender.cpp 2364-2423 [D]) y los caballetes / pinchos de los controles (cajas, sin modelo en el disco [I]).
// Se engancha al Renderer con el protocolo RenderOverlay (tres puntos: opacos, transparentes y pantalla).
import Foundation
import Metal
import simd

/// Algo que se dibuja dentro de las pasadas del Renderer (IA, HUD…).
protocol RenderOverlay: AnyObject {
    /// Pasada de escena, tras el coche opaco del jugador (profundidad con escritura).
    func encodeOpaque(_ enc: MTLRenderCommandEncoder, frame: SceneFrame)
    /// Pasada de escena, tras los transparentes (sin escribir profundidad).
    func encodeTransparent(_ enc: MTLRenderCommandEncoder, frame: SceneFrame)
    /// Tras el tono PS2, sobre la imagen final (HUD).
    func encodeScreen(_ cb: MTLCommandBuffer, target: MTLTexture)
    var drawCalls: Int { get }
    /// Sombras de coche (cuadrado unidad −1…1 → mundo) que la capa pide al Renderer tras su pasada opaca (CARSHADOW, doc 20 §4).
    var shadowQuads: [float4x4] { get }
}

extension RenderOverlay {
    var shadowQuads: [float4x4] { [] }
}

private let aiShaderSource = scenePreludeMSL + """

struct InstDraw { float4 color; float4 params; float4 extra; LightMat lm; };   // params: corte, -, -, pieza · extra.x: 1 piloto, 2 faro; y: alfa = brillo
struct VertexIn { float3 pos [[attribute(0)]]; float2 uv [[attribute(1)]]; half4 color [[attribute(2)]]; float4 normal [[attribute(3)]]; };
struct VOut { float4 pos [[position]]; float3 world; float3 normal; float2 uv; float4 color; float4 inst [[flat]]; };

vertex VOut vs_inst(VertexIn in [[stage_in]], uint iid [[instance_id]], constant FrameUniforms& F [[buffer(1)]],
                    constant InstDraw& D [[buffer(2)]], const device float4x4* mats [[buffer(3)]], const device float4* inst [[buffer(4)]]) {
    float4x4 m = mats[iid * 9 + uint(D.params.w)];
    VOut o;
    float4 w = m * float4(in.pos, 1);
    o.pos = F.viewProj * w; o.world = w.xyz;
    o.normal = normalize((m * float4(in.normal.xyz, 0)).xyz + 1e-6);
    o.uv = in.uv; o.color = float4(in.color) * D.color; o.inst = inst[iid];
    return o;
}

// Misma luz que fs_car (material de luz del juego + reflejo, SceneShading.swift) + emisión de pilotos y faros.
fragment float4 fs_inst(VOut in [[stage_in]], constant FrameUniforms& F [[buffer(1)]], constant InstDraw& D [[buffer(2)]],
                        texture2d<float> tex [[texture(0)]], sampler s [[sampler(1)]],
                        texture2d<float> env [[texture(1)]], sampler es [[sampler(2)]]) {
    float4 t = tex.sample(s, in.uv);
    float4 base = t * in.color;
    if (D.params.x > 0 && base.a <= D.params.x) discard_fragment();
    float gloss = 1;
    if (D.extra.y > 0.5) { gloss = t.a; base.a = in.color.a; }
    float4 c = carShade(F, D.lm, base, gloss, normalize(in.normal), in.world, env, es);
    if (D.extra.x == 1) c.rgb += base.rgb * in.inst.x * 4.0;        // pilotos al frenar
    if (D.extra.x == 2) c.rgb += base.rgb * in.inst.y * 1.5;        // faros
    return float4(sceneRGB(F, c.rgb, in.world), saturate(c.a));
}

// Destellos: cuadrado orientado a la cámara, suma (aditivo, en gamma), se apagan con la niebla.
struct Flare { float4 pos; float4 color; };
struct FlareOut { float4 pos [[position]]; float2 q; float4 color; };
struct FlareU { float4 right; float4 up; };
vertex FlareOut vs_flare(uint vid [[vertex_id]], uint iid [[instance_id]], constant FrameUniforms& F [[buffer(1)]],
                         const device Flare* fl [[buffer(3)]], constant FlareU& U [[buffer(4)]]) {
    float2 c = float2((vid == 1 || vid == 2 || vid == 4) ? 1.0 : -1.0, (vid == 2 || vid == 4 || vid == 5) ? 1.0 : -1.0);
    Flare f = fl[iid];
    float3 toCam = normalize(F.camPos.xyz - f.pos.xyz);
    float3 w = f.pos.xyz + toCam * 0.25 + (U.right.xyz * c.x + U.up.xyz * c.y) * f.pos.w;
    FlareOut o; o.pos = F.viewProj * float4(w, 1); o.q = c; o.color = f.color;
    o.color.rgb *= (1 - fogFactor(F, w));
    return o;
}
fragment float4 fs_flare(FlareOut in [[stage_in]]) {
    float r2 = dot(in.q, in.q);
    float a = exp(-r2 * 5.0) + 0.6 * exp(-r2 * 30.0);
    return float4(ps2Encode(in.color.rgb) * a, 1);
}
"""

/// Uniformes por tramo de los coches de la IA (`InstDraw` de MSL).
private struct InstDrawU { var color: float4; var params: float4; var extra: float4; var lm: LightMaterialGPU }

final class AIRenderer: RenderOverlay {
    let device: MTLDevice
    let textures: TextureCache
    unowned let world: AIWorld
    private var pInst: MTLRenderPipelineState!, pInstBlend: MTLRenderPipelineState!, pFlare: MTLRenderPipelineState!
    /// Renderer de la escena: texturas de fx/ (mapa de entorno de la vista, CARSHADOW) y materiales de luz (doc 20).
    weak var sceneRenderer: Renderer?
    private var envSampler: MTLSamplerState!
    /// Sombras de los coches cercanos de este fotograma (las dibuja el Renderer con CARSHADOW).
    private(set) var shadowQuads: [float4x4] = []
    private var depthWrite: MTLDepthStencilState!, depthRead: MTLDepthStencilState!
    private var sampler: [MTLSamplerState] = []
    private var ring: [(mats: MTLBuffer, inst: MTLBuffer, flares: MTLBuffer)] = []
    private var ringIndex = 0
    private static let maxInst = 96, maxFlares = 1024
    private var sawhorse: GPUMesh?, spike: GPUMesh?
    private(set) var drawCalls = 0
    private var batches: [(mesh: GPUMesh, start: Int, count: Int)] = []
    private var flareCount = 0
    let hud: PursuitHUD
    /// Coches que no son de la IA pero se dibujan igual (el coche de la prueba --traffic-test).
    var extraVehicles: [AIVehicle] = []

    init(device: MTLDevice, textures: TextureCache, world: AIWorld, outputFormat: MTLPixelFormat) throws {
        self.device = device; self.textures = textures; self.world = world
        hud = try PursuitHUD(device: device, outputFormat: outputFormat, police: world.police)
        let lib = try device.makeLibrary(source: aiShaderSource, options: nil)
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3; vd.attributes[0].offset = 0
        vd.attributes[1].format = .float2; vd.attributes[1].offset = 12
        vd.attributes[2].format = .half4; vd.attributes[2].offset = 20
        vd.attributes[3].format = .char4Normalized; vd.attributes[3].offset = 28
        vd.layouts[0].stride = MemoryLayout<Vertex>.stride
        func make(_ vs: String, _ fs: String, blend: Int, vertex: Bool) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: vs); d.fragmentFunction = lib.makeFunction(name: fs)
            if vertex { d.vertexDescriptor = vd }
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
        pInst = try make("vs_inst", "fs_inst", blend: 0, vertex: true)
        pInstBlend = try make("vs_inst", "fs_inst", blend: 1, vertex: true)
        pFlare = try make("vs_flare", "fs_flare", blend: 2, vertex: false)
        let es = MTLSamplerDescriptor()
        es.minFilter = .linear; es.magFilter = .linear; es.mipFilter = .linear; es.sAddressMode = .repeat; es.tAddressMode = .clampToEdge
        envSampler = device.makeSamplerState(descriptor: es)

        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .greaterEqual; ds.isDepthWriteEnabled = true
        depthWrite = device.makeDepthStencilState(descriptor: ds)
        ds.isDepthWriteEnabled = false
        depthRead = device.makeDepthStencilState(descriptor: ds)
        for w in 0..<4 {
            let sd = MTLSamplerDescriptor()
            sd.minFilter = .linear; sd.magFilter = .linear; sd.mipFilter = .linear; sd.maxAnisotropy = 8
            sd.sAddressMode = w & 1 != 0 ? .repeat : .clampToEdge; sd.tAddressMode = w & 2 != 0 ? .repeat : .clampToEdge
            sampler.append(device.makeSamplerState(descriptor: sd)!)
        }
        // Anillo: una entrada por vista y fotograma en vuelo (pantalla partida: hasta 4 vistas × 3 fotogramas + margen)
        for _ in 0..<16 {
            ring.append((device.makeBuffer(length: AIRenderer.maxInst * 9 * 64, options: .storageModeShared)!,
                         device.makeBuffer(length: AIRenderer.maxInst * 16, options: .storageModeShared)!,
                         device.makeBuffer(length: AIRenderer.maxFlares * 32, options: .storageModeShared)!))
        }
        sawhorse = AIRenderer.box(device: device, size: float3(0.35, 2.2, 1.0), colors: [float4(0.95, 0.42, 0.05, 1), float4(0.92, 0.92, 0.9, 1)])
        spike = AIRenderer.box(device: device, size: float3(0.5, 4.2, 0.06), colors: [float4(0.06, 0.06, 0.07, 1), float4(0.5, 0.5, 0.52, 1)])
    }

    /// Caja simple de dos colores (franjas) apoyada en z = 0: caballetes y tiras de pinchos.
    static func box(device: MTLDevice, size: float3, colors: [float4]) -> GPUMesh? {
        var verts: [Vertex] = [], idx: [UInt32] = []
        let h = size * 0.5
        let faces: [(float3, float3, float3)] = [(float3(1, 0, 0), float3(0, 1, 0), float3(0, 0, 1)), (float3(-1, 0, 0), float3(0, -1, 0), float3(0, 0, 1)),
                                                 (float3(0, 1, 0), float3(-1, 0, 0), float3(0, 0, 1)), (float3(0, -1, 0), float3(1, 0, 0), float3(0, 0, 1)),
                                                 (float3(0, 0, 1), float3(1, 0, 0), float3(0, 1, 0)), (float3(0, 0, -1), float3(0, 1, 0), float3(1, 0, 0))]
        var draws: [DrawRange] = []
        // Franjas: 5 trozos a lo largo de Y alternando colores (un tramo de dibujo por color)
        let strips = 5
        for ci in 0..<2 {
            let start = idx.count
            for k in stride(from: ci, to: strips, by: 2) {
                let y0 = -h.y + size.y * Float(k) / Float(strips), y1 = -h.y + size.y * Float(k + 1) / Float(strips)
                let lo = float3(-h.x, y0, 0), hi = float3(h.x, y1, size.z)
                let c = (lo + hi) * 0.5, e = (hi - lo) * 0.5
                for (n, u, v) in faces {
                    let base = UInt32(verts.count)
                    for (a, b) in [(-1, -1), (1, -1), (1, 1), (-1, 1)] as [(Float, Float)] {
                        let p = c + n * e * abs(n) + u * (a * simd_dot(e, abs(u))) + v * (b * simd_dot(e, abs(v)))
                        verts.append(Vertex(px: p.x, py: p.y, pz: p.z, u: 0, v: 0, r: half(1), g: half(1), b: half(1), a: half(1), normal: packNormal(n)))
                    }
                    idx += [base, base + 1, base + 2, base, base + 2, base + 3]
                }
            }
            draws.append(DrawRange(kind: .opaque, indexStart: start, indexCount: idx.count - start, texture: nil, color: float4(srgbToLinear(float3(colors[ci].x, colors[ci].y, colors[ci].z)), 1),
                                   cutoff: 0, role: nil, name: "prop\(ci)"))
        }
        guard let vb = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<Vertex>.stride, options: .storageModeShared),
              let ib = device.makeBuffer(bytes: idx, length: idx.count * 4, options: .storageModeShared) else { return nil }
        return GPUMesh(vertexBuffer: vb, indexBuffer: ib, draws: draws, bounds: AABB(min: -h, max: h), triangles: idx.count / 3)
    }

    /// Prepara instancias y destellos del fotograma (una vez, en la pasada opaca).
    private func prepare(frame: SceneFrame) {
        ringIndex = (ringIndex + 1) % ring.count
        let r = ring[ringIndex]
        let mats = r.mats.contents().bindMemory(to: float4x4.self, capacity: AIRenderer.maxInst * 9)
        let inst = r.inst.contents().bindMemory(to: float4.self, capacity: AIRenderer.maxInst)
        let fl = r.flares.contents().bindMemory(to: float4.self, capacity: AIRenderer.maxFlares * 2)
        batches.removeAll(keepingCapacity: true)
        flareCount = 0
        shadowQuads.removeAll(keepingCapacity: true)
        let frustum = Frustum(frame.proj * frame.view)
        var n = 0
        let t = frame.time
        // Agrupar por modelo
        var byModel: [ObjectIdentifier: [AIVehicle]] = [:]
        var order: [AIModel] = []
        for v in world.vehicles + extraVehicles {
            let b = AABB(min: v.pos - float3(v.radius, v.radius, 0.5), max: v.pos + float3(v.radius, v.radius, v.model.height + 0.5))
            guard frustum.intersects(b), simd_distance(v.pos, frame.camPos) < 900 else { continue }
            let k = ObjectIdentifier(v.model)
            if byModel[k] == nil { order.append(v.model) }
            byModel[k, default: []].append(v)
        }
        for m in order {
            let list = byModel[ObjectIdentifier(m)]!
            let start = n
            for v in list where n < AIRenderer.maxInst {
                let pm = v.partMatrices
                for k in 0..<9 { mats[n * 9 + k] = pm[k] }
                inst[n] = float4(v.braking ? 1 : 0.15, v.kind == .cop && v.lights ? 0 : 0.35, 0, 0)
                n += 1
                // Sombra (DrawAmbientShadow [D]): caja del coche × 1,05 con CARSHADOW, a ras de suelo
                if simd_distance(v.pos, frame.camPos) < 250 {
                    let body = pm[0] * m.local.inverse
                    shadowQuads.append(body * float4x4(translation: float3(0, 0, 0.1)) * float4x4(scale: float3(m.halfLength * 1.2, m.halfWidth * 1.18, 1)))
                }
                // Destellos de la barra de luces [D: CarRender.cpp 2364-2423]
                if v.lights, simd_distance(v.pos, frame.camPos) < 700 {
                    let body = pm[0] * m.local.inverse
                    let phase = Float(v.id) * 0.7
                    let pulse = powf(cos(24 * (t + phase)), 2)
                    let redOn: Float = cos(8 * (t + phase)) > 0.2 ? 1 : 0
                    let blueOn: Float = cos(8 * (t + phase) + .pi) > 0.2 ? 1 : 0
                    for (i, f) in m.flares.enumerated() where flareCount < AIRenderer.maxFlares {
                        let wp = body * float4(f.pos, 1)
                        var col = float3(0, 0, 0), size: Float = 0.55
                        switch f.kind {
                        case .red: col = float3(1.0, 0.08, 0.03) * redOn * (0.55 + 0.45 * pulse) * 6
                        case .blue: col = float3(0.08, 0.22, 1.0) * blueOn * (0.55 + 0.45 * pulse) * 6
                        case .white:
                            let wv = sin(pulse * cos((t + phase + 1.5 * Float(i)) * 12) * 3)
                            col = float3(1, 1, 0.95) * max(0, wv) * 2.5; size = 0.4
                        }
                        if simd_length_squared(col) < 1e-4 { continue }
                        fl[flareCount * 2] = float4(wp.x, wp.y, wp.z, size)
                        fl[flareCount * 2 + 1] = float4(col, 1)
                        flareCount += 1
                    }
                }
            }
            if n > start { batches.append((m.mesh, start, n - start)) }
        }
        // Caballetes y pinchos del control
        if let rb = world.police.roadblock {
            for (kind, mesh) in [(false, sawhorse), (true, spike)] {
                guard let mesh else { continue }
                let start = n
                for p in rb.props where p.spike == kind && n < AIRenderer.maxInst {
                    let m = float4x4(translation: p.pos) * float4x4(rotationZ: p.yaw)
                    for k in 0..<9 { mats[n * 9 + k] = m }
                    inst[n] = .zero; n += 1
                }
                if n > start { batches.append((mesh, start, n - start)) }
            }
        }
    }

    private func draw(_ enc: MTLRenderCommandEncoder, kinds: Set<MaterialKind>) {
        let r = ring[ringIndex]
        enc.setVertexBuffer(r.inst, offset: 0, index: 4)
        for b in batches {
            enc.setVertexBuffer(b.mesh.vertexBuffer, offset: 0, index: 0)
            enc.setVertexBuffer(r.mats, offset: b.start * 9 * 64, index: 3)
            enc.setVertexBuffer(r.inst, offset: b.start * 16, index: 4)
            for d in b.mesh.draws where d.visible && kinds.contains(d.kind) {
                let role: Float = d.role == "piloto" ? 1 : d.role == "faro" ? 2 : 0
                // Tráfico y policía: pintura con el material TRAFFIC del juego si su tira no trae uno conocido
                let lm = sceneRenderer?.fx?.carMaterial(d, paintFallback: "TRAFFIC") ?? .neutral
                var U = InstDrawU(color: d.color, params: float4(d.kind == .mask ? d.cutoff : 0, 0, 0, Float(d.part)), extra: float4(role, lm.p.w, 0, 0), lm: lm)
                enc.setVertexBytes(&U, length: MemoryLayout<InstDrawU>.stride, index: 2)
                enc.setFragmentBytes(&U, length: MemoryLayout<InstDrawU>.stride, index: 2)
                enc.setFragmentTexture(d.texture ?? textures.white, index: 0)
                enc.setFragmentSamplerState(sampler[d.wrap & 3], index: 1)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: d.indexCount, indexType: .uint32, indexBuffer: b.mesh.indexBuffer,
                                          indexBufferOffset: d.indexStart * 4, instanceCount: b.count)
                drawCalls += 1
            }
        }
    }

    private func bindEnv(_ enc: MTLRenderCommandEncoder, frame: SceneFrame) {
        enc.setFragmentTexture(sceneRenderer?.fxTexture(frame.lighting.envMap) ?? textures.white, index: 1)
        enc.setFragmentSamplerState(envSampler, index: 2)
    }

    func encodeOpaque(_ enc: MTLRenderCommandEncoder, frame: SceneFrame) {
        drawCalls = 0
        prepare(frame: frame)
        guard !batches.isEmpty else { return }
        bindEnv(enc, frame: frame)
        enc.setRenderPipelineState(pInst)
        enc.setDepthStencilState(depthWrite)
        draw(enc, kinds: [.opaque, .mask])
    }

    func encodeTransparent(_ enc: MTLRenderCommandEncoder, frame: SceneFrame) {
        if !batches.isEmpty {
            bindEnv(enc, frame: frame)
            enc.setRenderPipelineState(pInstBlend)
            enc.setDepthStencilState(depthRead)
            draw(enc, kinds: [.blend, .shadow, .additive, .water])
        }
        if flareCount > 0 {
            let v = frame.view
            var U = (float4(v.columns.0.x, v.columns.1.x, v.columns.2.x, 0), float4(v.columns.0.y, v.columns.1.y, v.columns.2.y, 0))
            enc.setRenderPipelineState(pFlare)
            enc.setDepthStencilState(depthRead)
            enc.setVertexBuffer(ring[ringIndex].flares, offset: 0, index: 3)
            enc.setVertexBytes(&U, length: 32, index: 4)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: flareCount)
            drawCalls += 1
        }
    }

    func encodeScreen(_ cb: MTLCommandBuffer, target: MTLTexture) { hud.encode(cb, target: target) }
}
