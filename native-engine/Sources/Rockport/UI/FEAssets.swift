// Datos de la interfaz original (FEng) que escribe tools/src/cli/frontend.ts en <datos>/frontend/:
// paquetes .fng en JSON, texturas de interfaz (PNG a su tamaño original), fuentes (métricas + campo de distancias) y textos.
// Formato: docs/es/17-interfaz.md. Todo se carga bajo demanda y se guarda en caché.
import Foundation
import Metal

// MARK: - JSON de los paquetes (lo que escribe tools/src/lib/feng.ts)

struct FEJPackage: Decodable {
    let name: String
    let resources: [FEJResource]
    let objects: [FEJObject]
    let responses: [FEJResponse]
    let targets: [FEJTarget]
    let buttons: Int
}
struct FEJResource: Decodable { let index: Int; let id: UInt32; let name: String; let type: Int; let hash: String }
struct FEJTarget: Decodable { let msg: UInt32; let guids: [UInt32] }
struct FEJObject: Decodable {
    let guid: UInt32
    let nameHash: UInt32
    let type: Int
    let flags: UInt32
    let resIndex: Int
    let parent: UInt32?
    let data: [Float]
    let imageFlags: UInt32?
    let string: FEJString?
    let multi: FEJMulti?
    let scripts: [FEJScript]
    let responses: [FEJResponse]
}
struct FEJString: Decodable { let text: String; let label: UInt32?; let format: UInt32; let leading: Int32; let maxWidth: UInt32 }
struct FEJMulti: Decodable { let tex: [UInt32]; let texFlags: [UInt32] }
struct FEJScript: Decodable {
    let id: UInt32
    let length: Int
    let flags: UInt32
    let chainTo: UInt32?
    let tracks: [FEJTrack]
    let events: [FEJEvent]
}
struct FEJTrack: Decodable { let param: Int; let size: Int; let interp: Int; let action: Int; let length: Int; let offset: Int; let keys: [FEJKey] }
struct FEJKey: Decodable { let t: Int; let v: [Float] }
struct FEJEvent: Decodable { let id: UInt32; let target: UInt32; let t: Int }
struct FEJResponse: Decodable { let msg: UInt32; let responses: [FEJResp] }
struct FEJResp: Decodable {
    let id: UInt32
    let param: UInt32
    let paramString: String?
    let target: UInt32
    enum K: String, CodingKey { case id, param, target }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        id = try c.decode(UInt32.self, forKey: .id)
        target = try c.decodeIfPresent(UInt32.self, forKey: .target) ?? 0
        if let n = try? c.decode(UInt32.self, forKey: .param) { param = n; paramString = nil }
        else { paramString = try? c.decode(String.self, forKey: .param); param = 0 }
    }
}

struct FEJFont: Decodable {
    struct Glyph: Decodable { let c: Int; let w: Int; let h: Int; let u: Int; let v: Int; let ox: Int; let oy: Int; let ax: Int; let kern: [[Int]]? }
    struct Atlas: Decodable { let w: Int; let h: Int }
    let name: String
    let hash: UInt32
    let height: Int
    let baselineOffset: Float
    let leadingScale: Float
    let glyphs: [Glyph]
    let textureHex: String
    let atlas: Atlas?
}

struct FEJIndex: Decodable {
    struct Pkg: Decodable { let name: String; let file: String }
    struct Font: Decodable { let name: String; let hash: String; let file: String }
    struct Tex: Decodable { let name: String; let w: Int; let h: Int; let blend: Int? }
    let format: Int
    let languages: [String]
    let packages: [Pkg]
    let fonts: [Font]
    let textures: [String: Tex]
}

/// FEHashUpper / bStringHash en mayúsculas (h = h·33 + c, inicio 0xFFFFFFFF) [D: FEList.cpp].
func feHash(_ s: String) -> UInt32 {
    var h: UInt32 = 0xffffffff
    for c in s.uppercased().unicodeScalars { h = h &* 33 &+ (c.value & 0xff) }
    return h
}

/// Hashes de mensajes y scripts del juego [D: FEngHashes/*.hpp, FEPackage.cpp].
enum FEH {
    static let initScript: UInt32 = 0x001744B3          // INIT
    static let appear: UInt32 = 0x5079C8F8              // APPEAR
    static let leave: UInt32 = 0x033113AC               // LEAVE
    static let hide: UInt32 = 0x0016A259                // HIDE
    static let show: UInt32 = 0x001CA7C0                // SHOW
    static let padAccept: UInt32 = 0x406415E3
    static let padBack: UInt32 = 0x911AB364
    static let padStart: UInt32 = 0xB5AF2461
    static let padUp: UInt32 = 0x72619778
    static let padDown: UInt32 = 0x911C0A4B
    static let padLeft: UInt32 = 0x9120409E
    static let padRight: UInt32 = 0xB5971BF1
    static let buttonPressed: UInt32 = 0x0C407210
    static let highlight: UInt32 = 0xABC08912            // __BUTTON_HIGHLIGHT__ (SetCurrentButton)
    static let unhighlight: UInt32 = 0x55D1E635
    static let leaveAll: UInt32 = 0x97BDB465
    static let leaveScreen: UInt32 = 0x587C018B
    static let initComplete: UInt32 = 0x35F8620B
    static let exitComplete: UInt32 = 0xE1FDE1D1
}

// MARK: - Recursos

/// Textura de interfaz en GPU: premultiplicada, rgba8 lineal en «espacio de pantalla» (como el GS del PS2, que mezcla en gamma).
struct FETexture { let tex: MTLTexture; let width: Int; let height: Int; let additive: Bool }

/// Fuente lista para dibujar: glifos por carácter y atlas de distancias (SDF) o, si falta, el mapa de bits original.
final class FEFont {
    struct Glyph { let w: Float; let h: Float; let u: Float; let v: Float; let ox: Float; let oy: Float; let ax: Float; let kern: [UInt16: Float] }
    let name: String
    let hash: UInt32
    let height: Float
    let baselineOffset: Float
    let leadingScale: Float
    let glyphs: [UInt16: Glyph]
    let atlasW: Float, atlasH: Float
    let texture: MTLTexture
    let isSDF: Bool
    init(_ j: FEJFont, texture: MTLTexture, sdf: Bool) {
        name = j.name; hash = j.hash; height = Float(j.height); baselineOffset = j.baselineOffset; leadingScale = j.leadingScale
        var g: [UInt16: Glyph] = [:]
        for x in j.glyphs {
            var k: [UInt16: Float] = [:]
            for p in x.kern ?? [] where p.count == 2 { k[UInt16(truncatingIfNeeded: p[0])] = Float(p[1]) }
            g[UInt16(truncatingIfNeeded: x.c)] = Glyph(w: Float(x.w), h: Float(x.h), u: Float(x.u), v: Float(x.v), ox: Float(x.ox), oy: Float(x.oy), ax: Float(x.ax), kern: k)
        }
        glyphs = g
        atlasW = Float(j.atlas?.w ?? texture.width); atlasH = Float(j.atlas?.h ?? texture.height)
        self.texture = texture; isSDF = sdf
    }
    /// ConvertCharacter [D: FEngFont.cpp]: ™, œ, espacio duro.
    static func convert(_ c: UInt16) -> UInt16 {
        var c = c
        if c >= 0xFF80 { c &= 0xFF }
        if c == 0x99 { return 0x2122 }
        if c == 0x9C { return 0x153 }
        if c == 0xA0 { return 0x20 }
        return c
    }
    func glyph(_ c: UInt16) -> Glyph? { glyphs[FEFont.convert(c)] }
    func advance(_ c: UInt16, prev: UInt16) -> Float {
        guard c != 13, let g = glyph(c) else { return 0 }
        return g.ax + (prev != 0 ? (g.kern[prev] ?? 0) : 0)
    }
}

final class FEAssets {
    let root: URL
    let device: MTLDevice
    let queue: MTLCommandQueue
    let index: FEJIndex
    let language: String
    private(set) var strings: [UInt32: String] = [:]
    private var fallbackStrings: [UInt32: String] = [:]
    private var packages: [String: FEJPackage] = [:]
    private var textures: [UInt32: FETexture?] = [:]
    private var fonts: [UInt32: FEFont?] = [:]
    private let pngDecoder: TextureCache
    let white: FETexture

    init?(dataRoot: URL, device: MTLDevice, queue: MTLCommandQueue, language: String? = nil) {
        root = dataRoot.appendingPathComponent("frontend")
        guard let d = try? Data(contentsOf: root.appendingPathComponent("index.json")),
              let idx = try? JSONDecoder().decode(FEJIndex.self, from: d) else { return nil }
        self.device = device; self.queue = queue; index = idx
        self.language = language ?? idx.languages.first ?? "english"
        pngDecoder = TextureCache(device: device)
        let wd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        let wt = device.makeTexture(descriptor: wd)!
        var px: UInt32 = 0xffffffff
        wt.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
        white = FETexture(tex: wt, width: 1, height: 1, additive: false)
        strings = loadStrings(self.language)
        if self.language != "english" { fallbackStrings = loadStrings("english") }
    }

    private func loadStrings(_ lang: String) -> [UInt32: String] {
        guard let d = try? Data(contentsOf: root.appendingPathComponent("strings/\(lang).json")),
              let m = try? JSONDecoder().decode([String: String].self, from: d) else { return [:] }
        var out: [UInt32: String] = [:]
        for (k, v) in m { if let h = UInt32(k, radix: 16) { out[h] = v } }
        return out
    }

    /// Texto del idioma para una etiqueta (GetLocalizedWideString [D]); nil si no existe.
    func string(_ label: UInt32) -> String? { strings[label] ?? fallbackStrings[label] }

    func package(_ name: String) -> FEJPackage? {
        let key = name.replacingOccurrences(of: ".fng", with: "", options: .caseInsensitive)
        if let p = packages[key] { return p }
        let url = root.appendingPathComponent("packages/\(key).json")
        guard let d = try? Data(contentsOf: url) else { fputs("FEng: no existe el paquete \(key)\n", stderr); return nil }
        do {
            let p = try JSONDecoder().decode(FEJPackage.self, from: d)
            packages[key] = p
            return p
        } catch { fputs("FEng: \(key).json ilegible: \(error)\n", stderr); return nil }
    }

    func hasTexture(_ hash: UInt32) -> Bool { index.textures[String(format: "%08x", hash)] != nil }

    /// Textura por hash del nombre (bStringHash del nombre sin extensión, en mayúsculas).
    func texture(_ hash: UInt32) -> FETexture? {
        if let t = textures[hash] { return t }
        let hex = String(format: "%08x", hash)
        var result: FETexture? = nil
        if let info = index.textures[hex], let data = try? Data(contentsOf: root.appendingPathComponent("textures/\(hex).png")),
           let img = pngDecoder.decodePNG(data), let t = upload(img, premultiply: true, label: info.name) {
            result = FETexture(tex: t, width: img.width, height: img.height, additive: info.blend == 2)
        }
        textures[hash] = result
        return result
    }

    func font(_ hash: UInt32) -> FEFont? {
        let h = hash
        if let f = fonts[h] { return f }
        var result: FEFont? = nil
        let hex = String(format: "%08x", h)
        if let entry = index.fonts.first(where: { $0.hash == hex }),
           let d = try? Data(contentsOf: root.appendingPathComponent(entry.file)),
           let j = try? JSONDecoder().decode(FEJFont.self, from: d) {
            let sdfURL = root.appendingPathComponent(entry.file.replacingOccurrences(of: ".json", with: ".sdf.png"))
            if let sd = try? Data(contentsOf: sdfURL), let img = pngDecoder.decodePNG(sd), let t = upload(img, premultiply: false, label: "sdf " + j.name) {
                result = FEFont(j, texture: t, sdf: true)
            } else if let th = UInt32(j.textureHex, radix: 16), let t = texture(th) {
                result = FEFont(j, texture: t.tex, sdf: false)
            }
        }
        fonts[h] = result
        return result
    }

    /// Sube RGBA8 (sin sRGB: la interfaz se mezcla en espacio de pantalla, como el PS2) con mipmaps.
    private func upload(_ img: TextureCache.Image, premultiply: Bool, label: String) -> MTLTexture? {
        var px = img.rgba
        if premultiply {
            for i in stride(from: 0, to: px.count, by: 4) {
                let a = UInt16(px[i + 3])
                px[i] = UInt8((UInt16(px[i]) * a + 127) / 255)
                px[i + 1] = UInt8((UInt16(px[i + 1]) * a + 127) / 255)
                px[i + 2] = UInt8((UInt16(px[i + 2]) * a + 127) / 255)
            }
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: img.width, height: img.height, mipmapped: true)
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        t.label = label
        px.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, img.width, img.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: img.width * 4) }
        if t.mipmapLevelCount > 1, let cb = queue.makeCommandBuffer(), let b = cb.makeBlitCommandEncoder() {
            b.generateMipmaps(for: t); b.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        }
        return t
    }
}
