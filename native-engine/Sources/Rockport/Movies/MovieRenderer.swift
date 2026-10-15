// Dibujo de una película a pantalla completa: negro, la imagen a 4:3 con bandas (la PS2 estiraba 512×416 a 4:3 [I]) y los
// subtítulos debajo, como el SubTitler del juego (texto blanco sobre una caja oscura). Sin el tono PS2: el juego no pasaba
// las películas por el tratamiento visual del mundo (se dibujan con el reproductor de películas, fuera de la escena) [I].
import Foundation
import Metal
import CoreVideo
import CoreText
import CoreGraphics
import AppKit

private let movieShaderSource = """
#include <metal_stdlib>
using namespace metal;
struct VOut { float4 pos [[position]]; float2 uv; };
vertex VOut movieVS(uint vid [[vertex_id]], constant float4 &rect [[buffer(0)]]) {
    float2 c = float2(float(vid & 1), float(vid >> 1));
    VOut o;
    o.pos = float4(mix(rect.xy, rect.zw, c), 0, 1);
    o.uv = float2(c.x, 1 - c.y);
    return o;
}
fragment float4 movieFS(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], constant float &alpha [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 c = t.sample(s, in.uv);
    return c * alpha;   // premultiplicado (subtítulos de CoreGraphics); la imagen es opaca
}
"""

final class MovieRenderer {
    let device: MTLDevice
    private var pipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private var cache: CVMetalTextureCache?
    private var subtitle: (text: String, width: Int, tex: MTLTexture, w: Int, h: Int)?

    init(device: MTLDevice) {
        self.device = device
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    }

    private func pipeline(_ fmt: MTLPixelFormat) -> MTLRenderPipelineState? {
        if let p = pipelines[fmt] { return p }
        guard let lib = try? device.makeLibrary(source: movieShaderSource, options: nil) else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "movieVS")
        d.fragmentFunction = lib.makeFunction(name: "movieFS")
        d.colorAttachments[0].pixelFormat = fmt
        d.colorAttachments[0].isBlendingEnabled = true
        d.colorAttachments[0].sourceRGBBlendFactor = .one
        d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        d.colorAttachments[0].sourceAlphaBlendFactor = .one
        d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let p = try? device.makeRenderPipelineState(descriptor: d)
        pipelines[fmt] = p
        return p
    }

    /// Rectángulo 4:3 centrado (NDC) dentro de un destino W×H.
    static func movieRect(width W: Int, height H: Int, aspect: Double = 4.0 / 3.0) -> (x0: Float, y0: Float, x1: Float, y1: Float, pxW: Int, pxH: Int) {
        let a = Double(W) / Double(max(1, H))
        if a > aspect {
            let w = aspect / a
            return (Float(-w), -1, Float(w), 1, Int(Double(W) * w), H)
        } else {
            let h = a / aspect
            return (-1, Float(-h), 1, Float(h), W, Int(Double(H) * h))
        }
    }

    /// Codifica el fotograma: fondo negro, imagen (si hay) y subtítulo (si hay).
    func encode(_ cb: MTLCommandBuffer, target: MTLTexture, image: CVPixelBuffer?, subtitle text: String?) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        defer { enc.endEncoding() }
        guard let pso = pipeline(target.pixelFormat) else { return }
        enc.setRenderPipelineState(pso)
        let r = MovieRenderer.movieRect(width: target.width, height: target.height)
        var one: Float = 1
        if let image, let cache {
            var cvTex: CVMetalTexture?
            let w = CVPixelBufferGetWidth(image), h = CVPixelBufferGetHeight(image)
            if CVMetalTextureCacheCreateTextureFromImage(nil, cache, image, nil, .bgra8Unorm, w, h, 0, &cvTex) == kCVReturnSuccess,
               let cvTex, let tex = CVMetalTextureGetTexture(cvTex) {
                var rect = SIMD4<Float>(r.x0, r.y0, r.x1, r.y1)
                enc.setVertexBytes(&rect, length: 16, index: 0)
                enc.setFragmentBytes(&one, length: 4, index: 0)
                enc.setFragmentTexture(tex, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                cb.addCompletedHandler { _ in _ = cvTex }   // la textura vive hasta que la GPU termina
            }
        }
        if let text, !text.isEmpty, let st = subtitleTexture(text, width: r.pxW, movieHeight: r.pxH) {
            // Abajo del cuadro de la película, centrado (caja del SubTitler)
            let ndcW = Float(st.w) / Float(target.width) * 2, ndcH = Float(st.h) / Float(target.height) * 2
            let bottom = r.y0 + (r.y1 - r.y0) * 0.06
            var rect = SIMD4<Float>(-ndcW / 2, bottom, ndcW / 2, bottom + ndcH)
            enc.setVertexBytes(&rect, length: 16, index: 0)
            enc.setFragmentBytes(&one, length: 4, index: 0)
            enc.setFragmentTexture(st.tex, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    /// Textura del subtítulo (se rehace solo cuando cambia el texto o el tamaño).
    private func subtitleTexture(_ text: String, width: Int, movieHeight: Int) -> (tex: MTLTexture, w: Int, h: Int)? {
        if let s = subtitle, s.text == text, s.width == width { return (s.tex, s.w, s.h) }
        guard let img = MovieRenderer.renderSubtitle(text, maxWidth: width, movieHeight: movieHeight) else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: img.w, height: img.h, mipmapped: false)
        d.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        img.pixels.withUnsafeBytes { tex.replace(region: MTLRegionMake2D(0, 0, img.w, img.h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: img.w * 4) }
        subtitle = (text, width, tex, img.w, img.h)
        return (tex, img.w, img.h)
    }

    /// Texto → imagen BGRA premultiplicada (caja negra al 60 % y letras blancas), del ancho justo.
    static func renderSubtitle(_ text: String, maxWidth: Int, movieHeight: Int) -> (pixels: [UInt8], w: Int, h: Int)? {
        let size = CGFloat(max(14, Double(movieHeight) * 0.042))
        let font = CTFontCreateWithName(("AvenirNextCondensed-DemiBold" as CFString), size, nil)
        let para = NSMutableParagraphStyle(); para.alignment = .center; para.lineSpacing = size * 0.12
        let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: para])
        let setter = CTFramesetterCreateWithAttributedString(attr)
        let maxText = CGFloat(maxWidth) * 0.86
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: attr.length), nil, CGSize(width: maxText, height: .greatestFiniteMagnitude), nil)
        let padX = size * 0.6, padY = size * 0.3
        let textW = ceil(fit.width) + 4, textH = ceil(fit.height) + 2   // un poco de holgura: el mismo ancho no vuelve a partir las líneas
        let w = Int(textW + padX * 2), h = Int(textH + padY * 2)
        guard w > 0, h > 0 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info) else { return false }
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.6))
            ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: size * 0.2, cornerHeight: size * 0.2, transform: nil))
            ctx.fillPath()
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: attr.length),
                                                 CGPath(rect: CGRect(x: padX, y: padY, width: textW, height: textH), transform: nil), nil)
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: size * 0.12, color: CGColor(gray: 0, alpha: 0.9))
            CTFrameDraw(frame, ctx)
            return true
        }
        return ok ? (px, w, h) : nil
    }
}
