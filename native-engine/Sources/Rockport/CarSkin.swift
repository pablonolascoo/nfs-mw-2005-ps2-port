// Coches predefinidos del juego (presets.json, tools/src/cli/presets.ts) y composición de la pintura como CarSkin.cpp.
//
// En el juego la carrocería no tiene textura propia: <COCHE>_SKIN1 se sustituye por DUMMY_SKINn, que CompositeSkin rellena
// al cargar el coche [D: CarSkin.cpp, CarInfo.cpp GetUsedCarTextureInfo]:
//   1. todo el lienzo = color base de la pintura (RED, GREEN, BLUE; alfa = GLOSS) [D]
//   2. capa de vinilo (1 en MW): <BASE>_<TEXTURE> + <BASE>_<TEXTURE>_MASK de CARS\<COCHE>\VINYLS.BIN, mismo tamaño que el lienzo.
//      m = byte R de la máscara: m ≥ 0x80 → píxel del vinilo; 0 < m < 0x80 → mezcla m/128; 0 → base [D: CompositeSkin 8 bits]
//      Con REMAP ≠ 0 el vinilo se recolorea con VINYL_COLOUR0_0…2 (ningún preset del disco lo usa) [D, pesos H].
//   3. Alerón (SPOILER_SKIN1), toma de techo (ROOF_SKIN) y GLOBAL_SKIN1 usan la misma textura compuesta [D: ReplaceSpoilerHash].
//   4. Llanta: CompositeRim tiñe <LLANTA>_WHEEL con PAINT_RIM según <LLANTA>_WHEEL_INNER_MASK [D: CompositeWheel32].
// Aquí se compone en CPU al doble de la resolución del PS2 (vinilos de 512×512 [V] → 1024×1024) con muestreo bilineal de
// imagen y máscara: los bordes quedan suaves sin inventar detalle. Luego se sube con mipmaps (TextureCache.upload).
import Foundation
import Metal
import simd

struct PresetColour: Decodable {
    let name: String
    let rgb: String
    let gloss: Int
    let finish: String
    let material: String?
    var srgb: float3 {
        let v = UInt32(rgb, radix: 16) ?? 0
        return float3(Float((v >> 16) & 255), Float((v >> 8) & 255), Float(v & 255)) / 255
    }
}

struct CarPreset: Decodable {
    struct Solid: Decodable { let slot: String; let part: String; let glb: String; let node: String }
    struct Vinyl: Decodable {
        let name: String; let texture: String; let image: String?; let mask: String?
        let remap: Int; let numColours: Int; let colours: [PresetColour?]
    }
    struct Rim: Decodable { let name: String; let texture: String?; let innerMask: String? }
    struct Tint: Decodable { let name: String; let material: String?; let rgb: String; let opacity: Float; let pearl: Bool }
    let name: String
    let car: String
    let base: String
    let blacklist: Int?
    let kit: Int
    let solids: [Solid]
    let paint: PresetColour?
    let vinyl: Vinyl?
    let rim: Rim?
    let rimPaint: PresetColour?
    let windowTint: Tint?
    let licensePlate: String?

    func solid(_ slot: String) -> Solid? { solids.first { $0.slot == slot } }
    /// Nombre del sólido sin el sufijo de LOD (_A…_E).
    static func stem(_ node: String) -> String { node.replacingOccurrences(of: "_[A-E]$", with: "", options: .regularExpression) }
}

enum CarPresets {
    private struct File: Decodable { let presets: [CarPreset] }
    private static var cache: (URL, [CarPreset])?
    private static let lock = NSLock()

    static func all(_ data: GameData) -> [CarPreset] {
        lock.lock(); defer { lock.unlock() }
        if let c = cache, c.0 == data.root { return c.1 }
        let list = (try? JSONDecoder().decode(File.self, from: Data(contentsOf: data.url("presets.json"))).presets) ?? []
        cache = (data.root, list)
        return list
    }

    static func named(_ name: String, in data: GameData) -> CarPreset? {
        all(data).first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Lista Negra 1…15 (RAZORMUSTANG = 1, BLn = n).
    static func blacklist(_ data: GameData) -> [CarPreset] {
        all(data).filter { $0.blacklist != nil }.sorted { ($0.blacklist ?? 0) < ($1.blacklist ?? 0) }
    }
}

enum CarSkin {
    private static var cache: [String: MTLTexture] = [:]
    private static let lock = NSLock()

    /// Lee un PNG de map-data a RGBA8 sin premultiplicar.
    static func image(_ data: GameData, _ rel: String, textures: TextureCache) -> TextureCache.Image? {
        guard let d = try? Data(contentsOf: data.url(rel)) else { return nil }
        return textures.decodePNG(d)
    }

    @inline(__always) private static func bilinear(_ img: TextureCache.Image, _ u: Float, _ v: Float, _ out: inout SIMD4<Float>) {
        let x = u * Float(img.width) - 0.5, y = v * Float(img.height) - 0.5
        let x0 = Int(floor(x)), y0 = Int(floor(y)), fx = x - Float(x0), fy = y - Float(y0)
        func px(_ xi: Int, _ yi: Int) -> SIMD4<Float> {
            let cx = min(max(xi, 0), img.width - 1), cy = min(max(yi, 0), img.height - 1), o = (cy * img.width + cx) * 4
            return SIMD4<Float>(Float(img.rgba[o]), Float(img.rgba[o + 1]), Float(img.rgba[o + 2]), Float(img.rgba[o + 3]))
        }
        let a = px(x0, y0), b = px(x0 + 1, y0), c = px(x0, y0 + 1), d = px(x0 + 1, y0 + 1)
        out = (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
    }

    /// Píxeles de la piel compuesta (RGBA8, alfa = brillo como en el juego ×2). nil si el preset no trae pintura.
    static func compose(_ preset: CarPreset, data: GameData, textures: TextureCache, scale: Int = 2) -> TextureCache.Image? {
        guard let paint = preset.paint else { return nil }
        let base = SIMD4<Float>(paint.srgb * 255, Float(min(255, paint.gloss * 2)))
        var vin: TextureCache.Image? = nil, mask: TextureCache.Image? = nil
        if let v = preset.vinyl, let i = v.image, let m = v.mask { vin = image(data, i, textures: textures); mask = image(data, m, textures: textures) }
        let srcW = vin?.width ?? 256, srcH = vin?.height ?? 256
        let W = srcW * scale, H = srcH * scale
        var out = [UInt8](repeating: 0, count: W * H * 4)
        // REMAP [D: RemapColour]: pesos = alfa, B y G del píxel del vinilo sobre VINYL_COLOUR0_0…2 [H: orden de canales en PS2]
        let remap = (preset.vinyl?.remap ?? 0) != 0
        let rc: [SIMD4<Float>] = (0..<3).map { i in
            if let cs = preset.vinyl?.colours, i < cs.count, let c = cs[i] { return SIMD4<Float>(c.srgb * 255, Float(min(255, c.gloss * 2))) }
            return SIMD4<Float>(i == 0 ? 255 : 0, i == 1 ? 255 : 0, i == 2 ? 255 : 0, 255)
        }
        out.withUnsafeMutableBufferPointer { o in
            DispatchQueue.concurrentPerform(iterations: H) { y in
                var s = SIMD4<Float>(0, 0, 0, 0), m = SIMD4<Float>(0, 0, 0, 0)
                let v = (Float(y) + 0.5) / Float(H)
                for x in 0..<W {
                    var c = base
                    if let vin, let mask {
                        let u = (Float(x) + 0.5) / Float(W)
                        bilinear(mask, u, v, &m)
                        let mr = m.x
                        if mr > 0.5 {
                            bilinear(vin, u, v, &s)
                            if remap {
                                let w = SIMD3<Float>(s.w, s.z, s.y) / 255
                                s = rc[0] * w.x + rc[1] * w.y + rc[2] * w.z
                                s.w = max(rc[0].w * w.x, max(rc[1].w * w.y, rc[2].w * w.z))
                            }
                            let k = min(1, mr / 128)
                            c = s * k + base * (1 - k)
                        }
                    }
                    let i = (y * W + x) * 4
                    o[i] = UInt8(min(255, max(0, c.x.rounded()))); o[i + 1] = UInt8(min(255, max(0, c.y.rounded())))
                    o[i + 2] = UInt8(min(255, max(0, c.z.rounded()))); o[i + 3] = UInt8(min(255, max(0, c.w.rounded())))
                }
            }
        }
        return TextureCache.Image(width: W, height: H, rgba: out)
    }

    /// Textura de GPU de la piel de un preset (se compone una vez por preset).
    static func texture(_ preset: CarPreset, data: GameData, textures: TextureCache) -> MTLTexture? {
        lock.lock()
        if let t = cache[preset.name] { lock.unlock(); return t }
        lock.unlock()
        guard let img = compose(preset, data: data, textures: textures) else { return nil }
        let t = textures.upload(img, label: "piel \(preset.name)")
        lock.lock(); cache[preset.name] = t; lock.unlock()
        return t
    }

    /// Llanta teñida con PAINT_RIM [D: CompositeWheel32]: c = mezcla(texel, texel × color, máscara/255); alfa del texel.
    static func rimTexture(_ preset: CarPreset, wheelPNG: Data, data: GameData, textures: TextureCache) -> MTLTexture? {
        guard let paint = preset.rimPaint, let maskRel = preset.rim?.innerMask,
              var img = textures.decodePNG(wheelPNG), let mask = image(data, maskRel, textures: textures) else { return nil }
        let key = "llanta \(preset.name)"
        lock.lock()
        if let t = cache[key] { lock.unlock(); return t }
        lock.unlock()
        let col = paint.srgb
        var m = SIMD4<Float>(0, 0, 0, 0)
        for y in 0..<img.height { for x in 0..<img.width {
            bilinear(mask, (Float(x) + 0.5) / Float(img.width), (Float(y) + 0.5) / Float(img.height), &m)
            let k = m.x / 255, i = (y * img.width + x) * 4
            for c in 0..<3 { let t = Float(img.rgba[i + c]); img.rgba[i + c] = UInt8(min(255, (t * (1 - k) + t * col[c] * k).rounded())) }
        } }
        let t = textures.upload(img, label: key)
        lock.lock(); cache[key] = t; lock.unlock()
        return t
    }
}
