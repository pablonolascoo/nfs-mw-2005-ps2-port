// Dibujo de paquetes FEng con Metal a la resolución nativa de la pantalla.
//
// - Lienzo virtual del juego: 640×480, origen en el centro (cFEngRender suma SCREEN_WIDTH/2, SCREEN_HEIGHT/2) [D].
//   Se escala a la pantalla conservando el aspecto 4:3 (franjas a los lados en 16:10/16:9); lo que el paquete pone
//   fuera de ese marco (fondos de 854 px de ancho) se dibuja igual, así que llena la pantalla.
// - Orden: como FEngine::Render [D]: por paquete, objetos ordenados por Z (de mayor a menor; con la misma Z, primero el
//   último del archivo: ordenación por radix estable recorrida al revés en RenderObjectList [V: asm SLUS-21351 0x2507C8]).
// - Transformación por objeto: T(pos)·T(pivote)·R·T(−pivote)·S(tamaño) y la del grupo padre delante [D: MakeRenderMatrix].
// - Color: 0…255 por canal; el del grupo multiplica (c·g + 128) >> 8 [D]. Las texturas van premultiplicadas.
// - Ampliación: imágenes con Catmull-Rom (bicúbica de 9 lecturas) sobre la textura original; letras con campo de
//   distancias (SDF ×4 hecho en el conversor) → bordes nítidos a cualquier tamaño. Ver docs/es/17-interfaz.md.
// - Se dibuja DESPUÉS del tono PS2, sobre la imagen final: en el PS2 la interfaz iba encima de la escena sin pasar por
//   ningún filtro, así que los colores de la interfaz quedan fieles.
import Foundation
import Metal
import simd

private let feShader = """
#include <metal_stdlib>
using namespace metal;
struct V { float2 pos; float2 uv; float2 muv; float4 color; };
struct O { float4 pos [[position]]; float2 uv; float2 muv; float4 color; };
vertex O fe_vs(uint vid [[vertex_id]], const device V* v [[buffer(0)]]) {
    O o; V x = v[vid];
    o.pos = float4(x.pos, 0, 1); o.uv = x.uv; o.muv = x.muv; o.color = x.color;
    return o;
}
// Catmull-Rom con 9 lecturas bilineales (forma optimizada estándar). Textura premultiplicada.
static float4 catmullRom(texture2d<float> t, sampler s, float2 uv) {
    float2 size = float2(t.get_width(), t.get_height());
    float2 sp = uv * size;
    float2 p1 = floor(sp - 0.5) + 0.5;
    float2 f = sp - p1;
    float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    float2 w3 = f * f * (-0.5 + 0.5 * f);
    float2 w12 = w1 + w2;
    float2 p0 = (p1 - 1.0) / size, p3 = (p1 + 2.0) / size, p12 = (p1 + w2 / w12) / size;
    float4 r = 0;
    r += t.sample(s, float2(p0.x, p0.y), level(0)) * w0.x * w0.y;
    r += t.sample(s, float2(p12.x, p0.y), level(0)) * w12.x * w0.y;
    r += t.sample(s, float2(p3.x, p0.y), level(0)) * w3.x * w0.y;
    r += t.sample(s, float2(p0.x, p12.y), level(0)) * w0.x * w12.y;
    r += t.sample(s, float2(p12.x, p12.y), level(0)) * w12.x * w12.y;
    r += t.sample(s, float2(p3.x, p12.y), level(0)) * w3.x * w12.y;
    r += t.sample(s, float2(p0.x, p3.y), level(0)) * w0.x * w3.y;
    r += t.sample(s, float2(p12.x, p3.y), level(0)) * w12.x * w3.y;
    r += t.sample(s, float2(p3.x, p3.y), level(0)) * w3.x * w3.y;
    r.a = clamp(r.a, 0.0, 1.0);
    r.rgb = clamp(r.rgb, 0.0, r.a);
    return r;
}
static float4 sampleUI(texture2d<float> t, sampler s, float2 uv) {
    // Ampliando (lo normal: 640×480 → 4K): bicúbica sobre el nivel 0. Reduciendo: trilineal con mipmaps.
    float2 px = fwidth(uv * float2(t.get_width(), t.get_height()));
    if (max(px.x, px.y) > 1.0) return t.sample(s, uv);
    return catmullRom(t, s, uv);
}
fragment float4 fe_image(O in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
    return sampleUI(t, s, in.uv) * in.color;
}
fragment float4 fe_masked(O in [[stage_in]], texture2d<float> t [[texture(0)]], texture2d<float> m [[texture(1)]],
                          sampler s [[sampler(0)]], sampler ms [[sampler(1)]]) {
    float mask = m.sample(ms, in.muv).a;
    return sampleUI(t, s, in.uv) * mask * in.color;
}
// Letras: campo de distancias (128 = borde). Antialias de un píxel de pantalla.
fragment float4 fe_sdf(O in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
    float d = t.sample(s, in.uv).a;
    float w = max(fwidth(d) * 0.75, 1.0 / 255.0);
    float a = smoothstep(0.5 - w, 0.5 + w, d);
    return in.color * a;
}
"""

/// Marco de la interfaz en la pantalla: lienzo 640×480 escalado con su aspecto y centrado.
struct FELayout {
    let width: Float, height: Float, scale: Float, ox: Float, oy: Float
    /// Escala horizontal (igual a `scale` salvo en los paquetes estirados).
    let scaleX: Float
    /// `stretch`: lienzo estirado a todo el ancho como el modo panorámico anamórfico del PS2 (solo paquetes a pantalla
    /// completa que no tienen versión WS_, p. ej. BUSTED_OVERLAY).
    init(width: Int, height: Int, stretch: Bool = false) {
        self.width = Float(width); self.height = Float(height)
        scale = min(Float(width) / 640, Float(height) / 480)
        scaleX = stretch ? max(scale, Float(width) / 640) : scale
        ox = (Float(width) - 640 * scaleX) / 2; oy = (Float(height) - 480 * scale) / 2
    }

    /// Pantalla partida (Multiplayer/SplitHUD.swift): la ventana del lienzo `canvas` (x0, y0, x1, y1 en unidades FEng, origen
    /// en el centro) se encaja con su aspecto y centrada en el rectángulo `rect` (píxeles del destino: x, y, ancho, alto).
    /// Con la ventana (−320, −240, 320, 240) y el destino entero es lo mismo que `init(width:height:)`.
    init(width: Int, height: Int, rect: SIMD4<Float>, canvas: SIMD4<Float>) {
        self.width = Float(width); self.height = Float(height)
        let cw = canvas.z - canvas.x, ch = canvas.w - canvas.y
        scale = min(rect.z / cw, rect.w / ch)
        scaleX = scale
        ox = rect.x + rect.z / 2 - ((canvas.x + canvas.z) / 2 + 320) * scale
        oy = rect.y + rect.w / 2 - ((canvas.y + canvas.w) / 2 + 240) * scale
        visibleWidthOverride = rect.z
    }
    private var visibleWidthOverride: Float?
    /// Media anchura visible en unidades del lienzo (320 en 4:3; 426,7 en 16:9).
    var visibleHalfWidth: Float { (visibleWidthOverride ?? width) / scale / 2 }
    /// Coordenadas FEng (origen en el centro del lienzo) → NDC.
    func ndc(_ p: SIMD2<Float>) -> SIMD2<Float> {
        let x = ox + (p.x + 320) * scaleX, y = oy + (p.y + 240) * scale
        return SIMD2(x / width * 2 - 1, 1 - y / height * 2)
    }
}

final class FERenderer {
    struct Vtx { var pos: SIMD2<Float>; var uv: SIMD2<Float>; var muv: SIMD2<Float>; var color: SIMD4<Float> }
    enum Mode { case image, masked, sdf }
    struct Draw { var start: Int; var count: Int; var tex: MTLTexture; var mask: MTLTexture?; var mode: Mode; var additive: Bool; var wrap: Int }

    let device: MTLDevice
    private var pImage: [Bool: MTLRenderPipelineState] = [:], pMasked: [Bool: MTLRenderPipelineState] = [:], pSDF: MTLRenderPipelineState!
    private let clampS: MTLSamplerState
    /// Muestreadores por modo de repetición (TilableUV: bit 0 U, bit 1 V).
    private var wrapS: [MTLSamplerState] = []
    private var ring: [MTLBuffer] = []
    private var ringIndex = 0
    private static let maxVerts = 120_000
    private var verts: [Vtx] = []
    private var draws: [Draw] = []
    private(set) var lastDraws = 0

    init(device: MTLDevice, outputFormat: MTLPixelFormat) throws {
        self.device = device
        let lib = try device.makeLibrary(source: feShader, options: nil)
        func make(_ fs: String, additive: Bool) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "fe_vs"); d.fragmentFunction = lib.makeFunction(name: fs)
            let c = d.colorAttachments[0]!
            c.pixelFormat = outputFormat
            c.isBlendingEnabled = true
            c.sourceRGBBlendFactor = .one; c.sourceAlphaBlendFactor = .one
            c.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
            c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: d)
        }
        for a in [false, true] { pImage[a] = try make("fe_image", additive: a); pMasked[a] = try make("fe_masked", additive: a) }
        pSDF = try make("fe_sdf", additive: false)
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear; sd.mipFilter = .linear
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        clampS = device.makeSamplerState(descriptor: sd)!
        for w in 0..<4 {
            sd.sAddressMode = w & 1 != 0 ? .repeat : .clampToEdge; sd.tAddressMode = w & 2 != 0 ? .repeat : .clampToEdge
            wrapS.append(device.makeSamplerState(descriptor: sd)!)
        }
        for _ in 0..<3 { ring.append(device.makeBuffer(length: FERenderer.maxVerts * MemoryLayout<Vtx>.stride, options: .storageModeShared)!) }
    }

    // MARK: Recolección (FEngine::Render + cFEngRender::Render*)

    struct Item { var z: Float; var order: Int; var obj: FEObj; var m: float4x4; var color: SIMD4<Float> }

    /// Matriz local de un objeto [D: MakeRenderMatrix]. `extraScale` solo para textos coreanos/chinos.
    static func local(_ o: FEObj) -> float4x4 {
        let p = o.pivot, s = o.size
        var m = float4x4(translation: o.pos) * float4x4(translation: p)
        let q = o.rot
        if q.imag != .zero || q.real != 1 { m = m * float4x4(q) }
        m = m * float4x4(translation: -p)
        return m * float4x4(scale: SIMD3(s.x, s.y, s.z == 0 ? 1 : s.z))
    }

    func collect(_ pkg: FEPackageRT) -> [Item] {
        var items: [Item] = []
        var order = 0
        func visit(_ o: FEObj, _ pm: float4x4, _ pc: SIMD4<Float>, _ inGroup: Bool) {
            let c = o.color
            if c.w <= 0 { return }                                // Col.a == 0 → no se dibuja (ni el grupo) [D: RenderGroup/RenderObject]
            // La bandera de invisible de un GRUPO no oculta a sus hijos: FEngine::RenderGroup solo mira el alfa; la visibilidad
            // se comprueba objeto a objeto al dibujar (FEngSetAllObjectsInPackageVisibility deja todos los grupos invisibles y
            // el HUD solo vuelve a encender las hojas que registra) [D: FEngine.cpp, FEngInterfaceFEObjects.cpp]
            if o.type != 5 && o.flags & 9 != 0 { return }         // invisible (bit 0) o solo PC (bit 3) [D: FEngIsVisible]
            let col = inGroup ? SIMD4<Float>((pc * c + 128) / 256).rounded(.down) : c
            let m = pm * FERenderer.local(o)
            if o.type == 5 {
                for ch in o.children { visit(ch, m, simd_clamp(col, .zero, SIMD4(repeating: 255)), true) }
                return
            }
            let anchor = pm * SIMD4(o.pivot + o.pos, 1)
            if anchor.z <= 0 { return }                           // Sorter.AddObject solo si z > 0 [D: FEngine::RenderObject]
            order += 1
            items.append(Item(z: anchor.z, order: order, obj: o, m: m, color: col))
        }
        for r in pkg.roots { visit(r, matrix_identity_float4x4, SIMD4(repeating: 255), false) }
        // Mayor Z primero; con la misma Z, primero el último recorrido [V]
        items.sort { $0.z != $1.z ? $0.z > $1.z : $0.order > $1.order }
        return items
    }

    // MARK: Geometría

    private func quad(_ m: float4x4, _ L: FELayout, x0: Float, y0: Float, x1: Float, y1: Float, uv0: SIMD2<Float>, uv1: SIMD2<Float>,
                      colors: [SIMD4<Float>], muv: [SIMD2<Float>] = []) {
        let corners: [SIMD2<Float>] = [SIMD2(x0, y0), SIMD2(x1, y0), SIMD2(x1, y1), SIMD2(x0, y1)]
        let uvs: [SIMD2<Float>] = [uv0, SIMD2(uv1.x, uv0.y), uv1, SIMD2(uv0.x, uv1.y)]
        var v: [Vtx] = []
        for i in 0..<4 {
            let p = m * SIMD4(corners[i].x, corners[i].y, 0, 1)
            let c = colors[min(i, colors.count - 1)] / 255
            v.append(Vtx(pos: L.ndc(SIMD2(p.x, p.y)), uv: uvs[i], muv: muv.isEmpty ? .zero : muv[i], color: SIMD4(c.x * c.w, c.y * c.w, c.z * c.w, c.w)))
        }
        verts.append(contentsOf: [v[0], v[1], v[2], v[0], v[2], v[3]])
    }

    private func addDraw(_ tex: MTLTexture, mask: MTLTexture? = nil, mode: Mode, additive: Bool, wrap: Int, start: Int) {
        let n = verts.count - start
        guard n > 0 else { return }
        if let last = draws.last, last.tex === tex, last.mask === mask, last.mode == mode, last.additive == additive, last.wrap == wrap, last.start + last.count == start {
            draws[draws.count - 1].count += n
        } else { draws.append(Draw(start: start, count: n, tex: tex, mask: mask, mode: mode, additive: additive, wrap: wrap)) }
    }

    private func emitImage(_ it: Item, _ pkg: FEPackageRT, _ L: FELayout) {
        let o = it.obj
        guard let t = pkg.assets.texture(o.handle) else { return }
        let ul = o.uvTL, lr = o.uvBR
        // Repetición: la de la textura (TextureInfo::TilableUV); los UV fuera de 0…1 sin ella se recortan al borde, así funcionan
        // los barridos de LEAVE/APPEAR (p. ej. OUTRUN_BACKING). Datos antiguos sin el campo: como antes [V: UV > 1 ⇒ If].
        let wrap = t.wrap ?? ((o.def.imageFlags ?? 0) & 3 != 0 || max(ul.x, ul.y, lr.x, lr.y) > 1.001 || min(ul.x, ul.y, lr.x, lr.y) < -0.001 ? 3 : 0)
        let start = verts.count
        if o.type == 9, o.data.count >= 37 {
            // Imagen con color por vértice: el juego usa solo VertexColors (b,g,r,a) [D: RenderCBVImage]
            let vc = (0..<4).map { i in SIMD4<Float>(o.data[21 + i * 4 + 2], o.data[21 + i * 4 + 1], o.data[21 + i * 4], o.data[21 + i * 4 + 3]) }
            quad(it.m, L, x0: -0.5, y0: -0.5, x1: 0.5, y1: 0.5, uv0: ul, uv1: lr, colors: vc)
            addDraw(t.tex, mode: .image, additive: t.additive, wrap: wrap, start: start)
        } else if o.type == 12, let maskHash = o.multiTex.first, maskHash != 0, let mt = pkg.assets.texture(maskHash) {
            // Multi-imagen con máscara girada [D: RenderMultiImage + rotate_uvs]
            let tw = Float(t.width), th = Float(t.height)
            let a = o.maskTL, b = o.maskBR
            var uvs: [SIMD2<Float>] = [SIMD2(a.x * tw, a.y * th), SIMD2(b.x * tw, a.y * th), SIMD2(b.x * tw, b.y * th), SIMD2(a.x * tw, b.y * th)]
            let pr = o.pivotRot
            let px = tw * pr.x - tw * 0.5, py = th * pr.y - th * 0.5
            let hw = (uvs[2].x - uvs[0].x) * 0.5, hh = (uvs[2].y - uvs[0].y) * 0.5
            let ang = pr.z * .pi / 180, sn = sin(ang), cs = cos(ang)
            for i in 0..<4 {
                let x = uvs[i].x - hw - px, y = uvs[i].y - hh - py
                uvs[i] = SIMD2((x * cs + y * sn + px + hw) / tw, (y * cs - x * sn + py + hh) / th)
            }
            quad(it.m, L, x0: -0.5, y0: -0.5, x1: 0.5, y1: 0.5, uv0: ul, uv1: lr, colors: [it.color], muv: uvs)
            addDraw(t.tex, mask: mt.tex, mode: .masked, additive: t.additive, wrap: wrap, start: start)
        } else {
            quad(it.m, L, x0: -0.5, y0: -0.5, x1: 0.5, y1: 0.5, uv0: ul, uv1: lr, colors: [it.color])
            addDraw(t.tex, mode: .image, additive: t.additive, wrap: wrap, start: start)
        }
    }

    /// Texto visible de un objeto: FEPrintf, o la etiqueta del idioma (si no lleva la bandera 2), o el texto del paquete [D: RenderString].
    static func text(of o: FEObj, assets: FEAssets) -> String {
        if let t = o.text { return t }
        if o.flags & 2 == 0, let l = o.label, let s = assets.string(l) { return s }
        return o.def.string?.text ?? ""
    }

    private func emitString(_ it: Item, _ pkg: FEPackageRT, _ L: FELayout) {
        let o = it.obj
        guard let font = pkg.assets.font(o.handle), let sdef = o.def.string else { return }
        let chars = Array(FERenderer.text(of: o, assets: pkg.assets).utf16)
        if chars.isEmpty { return }
        let layout = FETextLayout(font: font, chars: chars, format: sdef.format, leading: sdef.leading, maxWidth: sdef.maxWidth, flags: o.flags)
        var m = it.m
        let lineW = layout.lineWidth(from: 0)
        if sdef.maxWidth != 0 && lineW > Float(sdef.maxWidth) && sdef.format & 0x10 == 0 {
            m = m * float4x4(scale: SIMD3(Float(sdef.maxWidth) / lineW, 1, 1))
        }
        let start = verts.count
        let tw = font.atlasW, th = font.atlasH
        for g in layout.glyphs() {
            if let icon = g.icon {
                // Icono de botón «$NOMBRE$» [D: HandleJoyEventTexture]
                if let t = pkg.assets.texture(icon) {
                    let s2 = verts.count
                    quad(m, L, x0: g.x, y0: -Float(t.height) * 0.5, x1: g.x + Float(t.width), y1: Float(t.height) * 0.5,
                         uv0: SIMD2(0, 0), uv1: SIMD2(1, 1), colors: [it.color])
                    addDraw(t.tex, mode: .image, additive: false, wrap: 0, start: s2)
                }
                continue
            }
            let s2 = verts.count
            quad(m, L, x0: g.x, y0: g.y, x1: g.x + g.w, y1: g.y + g.h,
                 uv0: SIMD2(g.u / tw, g.v / th), uv1: SIMD2((g.u + g.uw + 1) / tw, (g.v + g.h) / th), colors: [it.color])
            addDraw(font.texture, mode: font.isSDF ? .sdf : .image, additive: false, wrap: 0, start: s2)
        }
        _ = start
    }

    // MARK: Pasada

    /// Dibuja los paquetes (en orden: el último queda encima) sobre `target`, que ya tiene la escena.
    func encode(_ cb: MTLCommandBuffer, target: MTLTexture, packages: [FEPackageRT]) {
        encode(cb, target: target, batches: [FEBatch(packages: packages, layout: nil, scissor: nil)])
    }

    /// Paquetes en grupos, cada uno con su marco (nil = el lienzo entero en el destino) y su recorte en píxeles
    /// (pantalla partida: el HUD de cada jugador en su cuarto de pantalla). Un solo búfer y un solo codificador.
    func encode(_ cb: MTLCommandBuffer, target: MTLTexture, batches: [FEBatch]) {
        let L0 = FELayout(width: target.width, height: target.height)
        let LS = FELayout(width: target.width, height: target.height, stretch: true)
        verts.removeAll(keepingCapacity: true); draws.removeAll(keepingCapacity: true)
        var cuts: [(draw: Int, scissor: MTLScissorRect?)] = []
        for b in batches {
            cuts.append((draws.count, b.scissor))
            for p in b.packages where p.visible {
                let L = b.layout ?? (p.stretch ? LS : L0)
                for it in collect(p) {
                    switch it.obj.type {
                    case 1, 9, 10, 11, 12: emitImage(it, p, L)
                    case 2: emitString(it, p, L)
                    default: break   // películas, listas: no se dibujan aquí
                    }
                    if verts.count > FERenderer.maxVerts - 6000 { break }
                }
            }
        }
        lastDraws = draws.count
        guard !draws.isEmpty else { return }
        ringIndex = (ringIndex + 1) % ring.count
        let buf = ring[ringIndex]
        verts.withUnsafeBytes { memcpy(buf.contents(), $0.baseAddress!, min($0.count, buf.length)) }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .load
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.label = "interfaz FEng"
        enc.setVertexBuffer(buf, offset: 0, index: 0)
        enc.setFragmentSamplerState(clampS, index: 1)
        let full = MTLScissorRect(x: 0, y: 0, width: target.width, height: target.height)
        var cut = 0
        for (i, d) in draws.enumerated() {
            while cut < cuts.count && cuts[cut].draw <= i {
                if cuts.count > 1 { enc.setScissorRect(cuts[cut].scissor ?? full) }
                cut += 1
            }
            switch d.mode {
            case .image: enc.setRenderPipelineState(pImage[d.additive]!)
            case .masked: enc.setRenderPipelineState(pMasked[d.additive]!); enc.setFragmentTexture(d.mask, index: 1)
            case .sdf: enc.setRenderPipelineState(pSDF)
            }
            enc.setFragmentTexture(d.tex, index: 0)
            enc.setFragmentSamplerState(wrapS[d.wrap & 3], index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: d.start, vertexCount: d.count)
        }
        enc.endEncoding()
    }
}

/// Grupo de paquetes con su marco y su recorte (FERenderer.encode(batches:)).
struct FEBatch {
    var packages: [FEPackageRT]
    var layout: FELayout?
    var scissor: MTLScissorRect?
}

/// Maquetación de texto como FEngFont::RenderString [D]: justificación, saltos «^» y «\n», ajuste de línea, interletraje.
struct FETextLayout {
    struct G { var x: Float; var y: Float; var w: Float; var h: Float; var u: Float; var v: Float; var uw: Float; var icon: UInt32? }
    let font: FEFont
    let chars: [UInt16]
    let format: UInt32
    let leading: Float
    let maxWidth: Float
    let flags: UInt32
    var wordWrap: Bool { format & 0x10 != 0 }

    init(font: FEFont, chars: [UInt16], format: UInt32, leading: Int32, maxWidth: UInt32, flags: UInt32) {
        self.font = font; self.chars = chars; self.format = format
        self.leading = Float(Int(Float(leading) * font.leadingScale)); self.maxWidth = Float(maxWidth); self.flags = flags
    }
    static func isNewline(_ c: UInt16) -> Bool { c == 10 || c == 94 }
    private func at(_ i: Int) -> UInt16 { i >= 0 && i < chars.count ? chars[i] : 0 }

    func lineWidth(from i0: Int) -> Float {
        var w: Float = 0, lastSpace: Float = 0, k = 0, i = i0
        while i < chars.count {
            let c = chars[i]
            if FETextLayout.isNewline(c) { break }
            if c == 32 { lastSpace = w }
            w += font.advance(c, prev: k == 0 ? 0 : at(i - 1))
            if maxWidth != 0 && maxWidth < w && wordWrap { if lastSpace > 0 { w = lastSpace }; break }
            k += 1; i += 1
        }
        return w
    }
    func nextWordWidth(_ i0: Int) -> Float {
        var w: Float = 0, i = i0
        while i < chars.count {
            w += font.advance(chars[i], prev: at(i - 1))
            let n = at(i + 1)
            if n == 32 || n == 0 || FETextLayout.isNewline(n) { break }
            i += 1
        }
        return w
    }
    func textHeight() -> Float {
        var h: Float = 0, lastNotReturn = true, cur: Float = 0
        for i in 0..<chars.count {
            let c = chars[i]
            var newLine = false
            if FETextLayout.isNewline(c) { newLine = true }
            else if c != 13 {
                lastNotReturn = true
                if wordWrap && maxWidth != 0 {
                    if c == 32 && maxWidth < cur + nextWordWidth(i) { newLine = true }
                    cur += font.advance(c, prev: at(i - 1))
                }
            }
            if newLine { lastNotReturn = false; cur = 0; h += leading + font.height }
        }
        if lastNotReturn { h += font.height }
        return h
    }
    func xOffset(_ w: Float) -> Float { format & 1 != 0 ? -w * 0.5 : (format & 2 != 0 ? -w : 0) }
    func yOffset(_ h: Float) -> Float { format & 4 != 0 ? -h * 0.5 : (format & 8 != 0 ? -h : 0) }

    func glyphs() -> [G] {
        var out: [G] = []
        var y = yOffset(textHeight())
        var x = xOffset(lineWidth(from: 0))
        var lineStart = x
        var i = 0
        let joyOK = flags & 0x820 == 0
        while i < chars.count {
            var c = chars[i]
            defer { i += 1 }
            if c == 32 && x == lineStart && wordWrap { continue }
            if flags & 0x20 == 0 && FETextLayout.isNewline(c) {
                if i + 1 >= chars.count { break }
                x = xOffset(lineWidth(from: i + 1)); y += font.height + leading; lineStart = x
                continue
            }
            if maxWidth != 0 && c == 32 && wordWrap && (x - lineStart) + nextWordWidth(i) > maxWidth {
                x = xOffset(lineWidth(from: i + 1)); y += font.height + leading; lineStart = x
            }
            if joyOK && c == 36 {   // '$'
                if at(i + 1) == 36 { i += 1; c = 36 }
                else if let end = chars[(i + 1)...].firstIndex(of: 36) {
                    let name = String(utf16CodeUnits: Array(chars[(i + 1)..<end]), count: end - i - 1).uppercased()
                    out.append(G(x: x, y: 0, w: 0, h: 0, u: 0, v: 0, uw: 0, icon: feHash(name)))
                    x += 32
                    i = end
                    continue
                }
            }
            guard let g = font.glyph(c) else { continue }
            let kern: Float = i > 0 ? (g.kern[at(i - 1)] ?? 0) : 0
            let gw = max(g.w, 4)
            if g.w > 0 && g.h > 0 {
                out.append(G(x: x + kern + g.ox, y: y + g.oy + font.baselineOffset, w: gw, h: g.h, u: g.u, v: g.v, uw: g.w, icon: nil))
            }
            x += font.advance(c, prev: i > 0 ? at(i - 1) : 0)
        }
        return out
    }
}

