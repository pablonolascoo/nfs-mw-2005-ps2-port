// Fundido a negro de los guiones (Game.Fade, EFadeScreenNoLoadingBarOn/Off [V: guiones del D-Day]): una capa negra sobre
// todo, HUD incluido, que sube o baja en medio segundo [I: duración].
import Foundation
import Metal
import simd

final class ScreenFade: RenderOverlay {
    var target: Float = 0
    private(set) var value: Float = 0
    private var pipeline: MTLRenderPipelineState?
    var drawCalls: Int { value > 0.001 ? 1 : 0 }

    init(device: MTLDevice, format: MTLPixelFormat) {
        let src = """
        #include <metal_stdlib>
        using namespace metal;
        vertex float4 fade_vs(uint v [[vertex_id]]) { float2 p = float2((v << 1) & 2, v & 2); return float4(p * 2 - 1, 0, 1); }
        fragment float4 fade_fs(constant float& a [[buffer(0)]]) { return float4(0, 0, 0, a); }
        """
        guard let lib = try? device.makeLibrary(source: src, options: nil) else { return }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "fade_vs"); d.fragmentFunction = lib.makeFunction(name: "fade_fs")
        let c = d.colorAttachments[0]!
        c.pixelFormat = format; c.isBlendingEnabled = true
        c.sourceRGBBlendFactor = .sourceAlpha; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
        c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try? device.makeRenderPipelineState(descriptor: d)
    }

    func update(dt: Float) {
        let step = dt / 0.5
        value = target > value ? min(target, value + step) : max(target, value - step)
    }

    func encodeOpaque(_ enc: MTLRenderCommandEncoder, frame: SceneFrame) {}
    func encodeTransparent(_ enc: MTLRenderCommandEncoder, frame: SceneFrame) {}
    func encodeScreen(_ cb: MTLCommandBuffer, target tex: MTLTexture) {
        guard value > 0.001, let pipeline else { return }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = tex; rp.colorAttachments[0].loadAction = .load; rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setRenderPipelineState(pipeline)
        var a = value
        enc.setFragmentBytes(&a, length: 4, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }
}

/// Textos de la historia del disco: SMS_MESSAGE_<n> y SMS_MESSAGE_<n>_FROM [V: strings, FEDatabase.hpp GetMsgHash [D]].
enum StoryText {
    static weak var assets: FEAssets?
    private static var es: Bool { assets?.language != "english" }
    private static func s(_ key: String) -> String? { assets?.string(feHash(key)) }
    static func sms(_ id: Int) -> String {
        let body = s("SMS_MESSAGE_\(id)")?.replacingOccurrences(of: "^^", with: " ").replacingOccurrences(of: "^", with: " ")
        let from = s("SMS_MESSAGE_\(id)_FROM")
        return [from, body].compactMap { $0 }.joined(separator: ": ").ifEmpty(es ? "Mensaje nuevo" : "New message")
    }
    /// ECellCall: la llamada usa el mismo número que el SMS con su texto [I: 10 = Mia, mancha de aceite].
    static func cellCall(_ id: Int) -> String { (es ? "Llamada · " : "Call · ") + sms(id) }
    static var call911: String { es ? "911: persecución en curso" : "911: pursuit in progress" }
    static var engineBlown: String { es ? "¡El motor ha reventado!" : "Your engine has blown!" }
    static var buyCar: String { es ? "Sin coche: compra uno en el concesionario" : "No car: buy one at the car lot" }
}

private extension String { func ifEmpty(_ f: String) -> String { isEmpty ? f : self } }
