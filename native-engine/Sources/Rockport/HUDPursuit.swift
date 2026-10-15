// HUD de persecución propio, SOLO PARA DEPURAR (`--debug-hud`). El juego usa siempre el HUD original (UI/FEHud.swift); sin los
// datos de frontend/ no hay HUD. Mínimo: solo aparece cuando la policía está metida.
//  - Arriba a la izquierda: «HEAT» y 5 barras de calor (se llenan con el nivel; roja la parte alcanzada).
//  - Abajo, centrada: la barra de persecución. Izquierda «EVADE» (verde), derecha «BUSTED» (roja). Durante la persecución
//    se llena desde el centro con el medidor del juego (AIPursuit::GetPursuitMeter [D]); el arresto la llena hacia la derecha.
//    En enfriamiento pasa a «COOLDOWN» y se llena de izquierda a derecha con la evasión.
//  - Al acabar: «BUSTED» o «EVADED» en grande unos segundos.
// Se dibuja tras el tono PS2, sobre la imagen final, con texto de CoreText en texturas (sin menús ni ventanas).
import Foundation
import Metal
import CoreText
import CoreGraphics
import AppKit
import simd

private let hudShader = """
#include <metal_stdlib>
using namespace metal;
struct Q { float4 rect; float4 color; float4 uv; };   // rect en NDC (x0, y0, x1, y1), uv (u0, v0, u1, v1)
struct O { float4 pos [[position]]; float2 uv; float4 color; };
vertex O vs_hud(uint vid [[vertex_id]], constant Q& q [[buffer(0)]]) {
    float2 c = float2((vid == 1 || vid == 2 || vid == 4) ? 1.0 : 0.0, (vid == 2 || vid == 4 || vid == 5) ? 1.0 : 0.0);
    O o;
    o.pos = float4(mix(q.rect.x, q.rect.z, c.x), mix(q.rect.y, q.rect.w, c.y), 0, 1);
    o.uv = float2(mix(q.uv.x, q.uv.z, c.x), mix(q.uv.w, q.uv.y, c.y));
    o.color = q.color;
    return o;
}
fragment float4 fs_hud(O in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
    float4 c = t.sample(s, in.uv) * in.color;
    return c;
}
"""

final class PursuitHUD {
    let device: MTLDevice
    unowned let police: PoliceManager
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let white: MTLTexture
    private var textCache: [String: MTLTexture] = [:]
    /// Visible siempre que haya persecución; también se puede forzar (pruebas).
    var forceVisible = false
    /// Apagado salvo con `--debug-hud`: no es la interfaz del juego (esa es UI/FEHud.swift).
    static let debugEnabled = CommandLine.arguments.contains("--debug-hud")
    var enabled = PursuitHUD.debugEnabled

    // Colores del HUD de MW (ámbar/naranja del juego, verde de evasión, rojo de arresto)
    static let amber = float4(1.0, 0.62, 0.12, 1)
    static let green = float4(0.30, 0.95, 0.42, 1)
    static let red = float4(1.0, 0.16, 0.10, 1)
    static let blue = float4(0.35, 0.65, 1.0, 1)
    static let dark = float4(0, 0, 0, 0.55)

    init(device: MTLDevice, outputFormat: MTLPixelFormat, police: PoliceManager) throws {
        self.device = device; self.police = police
        let lib = try device.makeLibrary(source: hudShader, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "vs_hud"); d.fragmentFunction = lib.makeFunction(name: "fs_hud")
        d.colorAttachments[0].pixelFormat = outputFormat
        let c = d.colorAttachments[0]!
        c.isBlendingEnabled = true
        c.sourceRGBBlendFactor = .sourceAlpha; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
        c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: d)
        let sd = MTLSamplerDescriptor(); sd.minFilter = .linear; sd.magFilter = .linear
        sampler = device.makeSamplerState(descriptor: sd)!
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        white = device.makeTexture(descriptor: td)!
        var px: [UInt8] = [255, 255, 255, 255]
        white.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
    }

    /// Texto blanco en una textura (se tiñe al dibujar). Fuente condensada, gruesa e inclinada como la de MW.
    private func text(_ s: String, px: CGFloat) -> MTLTexture? {
        let key = "\(s)|\(Int(px))"
        if let t = textCache[key] { return t }
        let font = NSFont(name: "AvenirNextCondensed-HeavyItalic", size: px) ?? NSFont(name: "Futura-CondensedExtraBold", size: px) ?? NSFont.boldSystemFont(ofSize: px)
        let attr = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor.white, .kern: px * 0.06])
        let line = CTLineCreateWithAttributedString(attr)
        let b = CTLineGetBoundsWithOptions(line, [])
        let W = max(4, Int(ceil(b.width + px * 0.4))), H = max(4, Int(ceil(px * 1.3)))
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setShouldAntialias(true)
        ctx.textPosition = CGPoint(x: px * 0.15, y: px * 0.28)
        CTLineDraw(line, ctx)
        guard let data = ctx.data else { return nil }
        // Premultiplicado → recto (el blending es sourceAlpha)
        let p = data.bindMemory(to: UInt8.self, capacity: W * H * 4)
        for i in 0..<(W * H) { let a = p[i * 4 + 3]; if a > 0 { p[i * 4] = 255; p[i * 4 + 1] = 255; p[i * 4 + 2] = 255 } }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: W, height: H, mipmapped: false)
        guard let t = device.makeTexture(descriptor: td) else { return nil }
        // CGContext guarda de arriba abajo: el shader invierte v
        t.replace(region: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0, withBytes: data, bytesPerRow: W * 4)
        textCache[key] = t
        return t
    }

    var visible: Bool { enabled && (forceVisible || police.state != .none) }

    func encode(_ cb: MTLCommandBuffer, target: MTLTexture) {
        guard visible else { return }
        let W = Float(target.width), H = Float(target.height)
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .load
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.label = "HUD persecución"
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentSamplerState(sampler, index: 0)
        let u = H / 1080   // unidad: píxeles de una pantalla de 1080 líneas

        func rect(_ x: Float, _ y: Float, _ w: Float, _ h: Float, _ c: float4, _ tex: MTLTexture? = nil) {
            // x, y desde arriba a la izquierda, en píxeles
            var q = (float4(x / W * 2 - 1, 1 - (y + h) / H * 2, (x + w) / W * 2 - 1, 1 - y / H * 2), c, float4(0, 0, 1, 1))
            enc.setVertexBytes(&q, length: 48, index: 0)
            enc.setFragmentTexture(tex ?? white, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        /// Texto con su caja; `align` 0 izquierda, 0,5 centro, 1 derecha. Devuelve el ancho.
        @discardableResult
        func label(_ s: String, _ x: Float, _ y: Float, _ px: Float, _ c: float4, align: Float = 0) -> Float {
            guard let t = text(s, px: CGFloat(px)) else { return 0 }
            let w = Float(t.width), h = Float(t.height)
            rect(x - w * align + 2 * u, y + 2 * u, w, h, float4(0, 0, 0, 0.6 * c.w), t)   // sombra
            rect(x - w * align, y, w, h, c, t)
            return w
        }

        let pm = police
        // 1. Calor (arriba a la izquierda): 5 barras
        let hx = 48 * u, hy = 40 * u
        label("HEAT", hx, hy, 30 * u, PursuitHUD.amber)
        let maxHeat = Int(AIConfig.maxOpenWorldHeat)
        for i in 0..<maxHeat {
            let bx = hx + 92 * u + Float(i) * 30 * u, by = hy + 8 * u
            rect(bx, by, 24 * u, 22 * u, PursuitHUD.dark)
            let fill = max(0, min(1, pm.heat - Float(i)))
            if fill > 0 { rect(bx + 2 * u, by + 2 * u, 20 * u * fill, 18 * u, i < Int(pm.heat) ? PursuitHUD.red : PursuitHUD.amber) }
        }
        let cops = pm.copsInPursuit
        if pm.inPursuit { label("COPS \(cops)", hx, hy + 42 * u, 24 * u, float4(1, 1, 1, 0.9)) }

        // 2. Barra de persecución (abajo, centrada)
        let bw = min(W * 0.42, 820 * u), bh = 16 * u
        let bx = (W - bw) / 2, by = H - 120 * u
        switch pm.state {
        case .chase:
            rect(bx - 3 * u, by - 3 * u, bw + 6 * u, bh + 6 * u, PursuitHUD.dark)
            let mid = bx + bw / 2
            let bust = pm.bustTimer / PoliceManager.bustedTimeout
            let m = pm.meter
            if bust > 0.01 { rect(mid, by, bw / 2 * min(1, bust), bh, PursuitHUD.red) }
            else if m > 0 { rect(mid, by, bw / 2 * min(1, m * 2), bh, PursuitHUD.red) }
            else if m < 0 { let w = bw / 2 * min(1, -m * 2); rect(mid - w, by, w, bh, PursuitHUD.green) }
            rect(mid - 1.5 * u, by - 6 * u, 3 * u, bh + 12 * u, float4(1, 1, 1, 0.9))
            label("EVADE", bx, by - 40 * u, 28 * u, PursuitHUD.green)
            label("BUSTED", bx + bw, by - 40 * u, 28 * u, PursuitHUD.red, align: 1)
            label("PURSUIT", bx + bw / 2, by + bh + 8 * u, 22 * u, PursuitHUD.amber, align: 0.5)
        case .cooldown:
            rect(bx - 3 * u, by - 3 * u, bw + 6 * u, bh + 6 * u, PursuitHUD.dark)
            rect(bx, by, bw * min(1, pm.evade), bh, PursuitHUD.blue)
            label("COOLDOWN", bx + bw / 2, by - 44 * u, 32 * u, PursuitHUD.blue, align: 0.5)
        case .busted:
            label("BUSTED", W / 2, H * 0.38, 110 * u, PursuitHUD.red, align: 0.5)
        case .evaded:
            label("EVADED", W / 2, H * 0.38, 110 * u, PursuitHUD.green, align: 0.5)
        case .none:
            break
        }
        enc.endEncoding()
    }
}
