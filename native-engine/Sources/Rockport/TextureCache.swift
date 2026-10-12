// Caché de texturas compartida por todas las casillas y coches.
// - PNG descodificado con ImageIO SIN premultiplicar el alfa: muchas texturas del juego son "moduladas"
//   (alfa ≈ 0 pero opacas) y premultiplicar destruiría su color (ver viewer/src/tile-worker.ts).
// - Mipmaps con filtro de caja en CPU (en el hilo de carga), subida a una textura privada de GPU con un blit.
// - Formato sRGB: la GPU convierte a lineal al muestrear.
// - Una entrada por ruta; si dos casillas piden la misma textura a la vez, la segunda espera a la primera.
import Foundation
import Metal
import ImageIO
import CoreGraphics

final class TextureCache {
    private final class Entry {
        var texture: MTLTexture?
        let group = DispatchGroup()
    }

    let device: MTLDevice
    let queue: MTLCommandQueue
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()
    let white: MTLTexture
    private(set) var bytesResident = 0

    init(device: MTLDevice) {
        self.device = device
        // Cola propia para subidas: así los hilos de carga nunca bloquean la cola del dibujo
        // (una cola admite 64 búferes de comandos pendientes; con cientos de texturas el hilo principal se paraba).
        self.queue = device.makeCommandQueue(maxCommandBufferCount: 256)!
        self.queue.label = "subidas de texturas"
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: 1, height: 1, mipmapped: false)
        d.storageMode = .shared
        white = device.makeTexture(descriptor: d)!
        var px: UInt32 = 0xffffffff
        white.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    /// Textura de un archivo PNG (casillas). Bloquea el hilo que llama mientras carga: usar fuera del hilo principal.
    func texture(url: URL) -> MTLTexture? {
        texture(key: url.path) { try? Data(contentsOf: url) }
    }

    /// Textura de un PNG en memoria (coches con imágenes embebidas). `key` debe ser único.
    func texture(key: String, data: @escaping () -> Data?) -> MTLTexture? {
        lock.lock()
        if let e = entries[key] {
            lock.unlock()
            e.group.wait()
            return e.texture
        }
        let e = Entry()
        e.group.enter()
        entries[key] = e
        lock.unlock()
        defer { e.group.leave() }
        guard let bytes = data(), let img = decodePNG(bytes) else { return nil }
        e.texture = upload(img, label: key)
        return e.texture
    }

    struct Image { var width: Int; var height: Int; var rgba: [UInt8] }

    /// Descodifica a RGBA8 sin premultiplicar.
    func decodePNG(_ data: Data) -> Image? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let w = cg.width, h = cg.height
        var out = [UInt8](repeating: 255, count: w * h * 4)
        let alpha = cg.alphaInfo
        let order = cg.bitmapInfo.intersection(.byteOrderMask)
        let straight = (alpha == .last || alpha == .noneSkipLast || alpha == .none) && (order == [] || order == .byteOrder32Big || cg.bitsPerPixel == 24)
        if cg.bitsPerComponent == 8, straight, let provider = cg.dataProvider, let cf = provider.data {
            let src = CFDataGetBytePtr(cf)!
            let bpr = cg.bytesPerRow
            if cg.bitsPerPixel == 32 {
                out.withUnsafeMutableBufferPointer { o in
                    for y in 0..<h { memcpy(o.baseAddress! + y * w * 4, src + y * bpr, w * 4) }
                }
                if alpha == .noneSkipLast { for i in stride(from: 3, to: out.count, by: 4) { out[i] = 255 } }
                return Image(width: w, height: h, rgba: out)
            }
            if cg.bitsPerPixel == 24 {
                for y in 0..<h { for x in 0..<w {
                    let s = y * bpr + x * 3, d = (y * w + x) * 4
                    out[d] = src[s]; out[d + 1] = src[s + 1]; out[d + 2] = src[s + 2]
                } }
                return Image(width: w, height: h, rgba: out)
            }
        }
        // Formato raro (paleta, gris, 16 bits): se dibuja en un contexto RGBA (premultiplicado; solo como reserva).
        guard let ctx = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Image(width: w, height: h, rgba: out)
    }

    /// Crea la textura privada con todos sus mipmaps (calculados aquí) y la sube con un blit.
    func upload(_ img: Image, label: String) -> MTLTexture? {
        var levels: [(w: Int, h: Int, px: [UInt8])] = [(img.width, img.height, img.rgba)]
        while levels.last!.w > 1 || levels.last!.h > 1 {
            let p = levels.last!
            let w = max(1, p.w / 2), h = max(1, p.h / 2)
            var m = [UInt8](repeating: 0, count: w * h * 4)
            p.px.withUnsafeBufferPointer { s in
                m.withUnsafeMutableBufferPointer { d in
                    for y in 0..<h {
                        let y0 = min(y * 2, p.h - 1) * p.w, y1 = min(y * 2 + 1, p.h - 1) * p.w
                        for x in 0..<w {
                            let x0 = min(x * 2, p.w - 1), x1 = min(x * 2 + 1, p.w - 1)
                            let a = (y0 + x0) * 4, b = (y0 + x1) * 4, c = (y1 + x0) * 4, e = (y1 + x1) * 4, o = (y * w + x) * 4
                            for k in 0..<4 { d[o + k] = UInt8((UInt16(s[a + k]) + UInt16(s[b + k]) + UInt16(s[c + k]) + UInt16(s[e + k]) + 2) >> 2) }
                        }
                    }
                }
            }
            levels.append((w, h, m))
        }
        let total = levels.reduce(0) { $0 + $1.px.count }
        guard let staging = device.makeBuffer(length: total, options: .storageModeShared) else { return nil }
        var offsets: [Int] = []
        var off = 0
        for l in levels {
            offsets.append(off)
            _ = l.px.withUnsafeBytes { memcpy(staging.contents() + off, $0.baseAddress!, l.px.count) }
            off += l.px.count
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: img.width, height: img.height, mipmapped: true)
        d.mipmapLevelCount = levels.count
        d.storageMode = .private
        d.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: d), let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return nil }
        tex.label = label
        for (i, l) in levels.enumerated() {
            blit.copy(from: staging, sourceOffset: offsets[i], sourceBytesPerRow: l.w * 4, sourceBytesPerImage: l.w * l.h * 4,
                      sourceSize: MTLSize(width: l.w, height: l.h, depth: 1), to: tex, destinationSlice: 0, destinationLevel: i,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        }
        blit.endEncoding()
        // Cola distinta de la del dibujo: se espera aquí (hilo de carga) a que la copia termine, y solo entonces
        // la textura queda disponible para las casillas. El hilo principal nunca espera.
        cb.commit()
        cb.waitUntilCompleted()
        lock.lock(); bytesResident += total; lock.unlock()
        return tex
    }
}
