// Sonido del disco: índice sound/sound.json (lo escribe tools/src/cli/sound.ts) y bancos ABKC / motores Gnsu.
// La app decodifica sola los tres códecs del juego (igual que tools/src/lib/abk.ts; comprobado contra vgmstream):
//   PS-ADPCM («VAG», SPU de PS2) · EA-XA v2 (bancos *_EE) · EA-XAS (motores granulares .GIN, coma flotante como la decomp).
// Formatos: docs/es/16-audio-y-voces.md §7.
import Foundation

/// Muestra decodificada (mono, float −1…1).
struct SFXSample {
    let data: [Float]
    let rate: Int
    /// [inicio, fin incluido] del bucle, o nil.
    let loop: (Int, Int)?
    var duration: Double { Double(data.count) / Double(rate) }
}

final class SFXLibrary {
    let root: URL
    let json: [String: Any]
    private let banks: [String: [[Any]]]
    let gins: [String: [String: Any]]
    let engines: [String: [String: Any]]
    let turbos: [String: [String: Any]]
    let shifts: [String: [String: Any]]
    let acceltrans: [String: [String: Any]]
    let cars: [String: [String: Any]]
    let surfaces: [String: [String: Any]]
    let global: [String: [String?]]
    let stitches: [[String: Any]?]
    private var files: [String: Data] = [:]
    private var samples: [String: SFXSample] = [:]
    private var ginCache: [String: GinsuData] = [:]
    private let lock = NSLock()

    /// `root` = carpeta de datos del disco (map-data/<ID> o Application Support/Rockport/<ID>).
    init?(root: URL) {
        self.root = root.appendingPathComponent("sound")
        guard let d = try? Data(contentsOf: self.root.appendingPathComponent("sound.json")),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        json = j
        func dict(_ k: String) -> [String: [String: Any]] {
            (j[k] as? [String: Any] ?? [:]).compactMapValues { $0 as? [String: Any] }
        }
        banks = (j["banks"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? [String: Any])?["sounds"] as? [[Any]] }
        gins = dict("gins"); engines = dict("engines"); turbos = dict("turbos"); shifts = dict("shifts")
        acceltrans = dict("acceltrans"); cars = dict("cars"); surfaces = dict("surfaces")
        global = (j["global"] as? [String: Any] ?? [:]).compactMapValues { $0 as? [String?] ?? ($0 as? [Any])?.map { $0 as? String } }
        stitches = (j["stitches"] as? [Any] ?? []).map { $0 as? [String: Any] }
    }

    var bankCount: Int { banks.count }
    var bankNames: [String] { banks.keys.sorted() }
    func soundCount(_ bank: String) -> Int { banks[bank]?.count ?? 0 }

    private func file(_ path: String) -> Data? {
        if let d = files[path] { return d }
        guard let d = try? Data(contentsOf: root.appendingPathComponent(path), options: .alwaysMapped) else { return nil }
        files[path] = d
        return d
    }

    /// Sonido `n` (posición en la lista del banco, no el índice BNK) de un banco: decodificado una vez y guardado.
    func sample(_ bank: String, _ n: Int) -> SFXSample? {
        let key = "\(bank)#\(n)"
        lock.lock(); defer { lock.unlock() }
        if let s = samples[key] { return s }
        guard let list = banks[bank], n >= 0, n < list.count, let d = file(bank) else { return nil }
        let e = list[n]
        guard e.count >= 8, let codec = e[1] as? String, let rate = e[2] as? Int, let count = e[3] as? Int,
              let offs = e[5] as? [Int], let ls = e[6] as? Int, let le = e[7] as? Int else { return nil }
        // Estéreo (solo FE_MB): se mezcla a mono
        var mono = [Float](repeating: 0, count: count)
        for o in offs {
            let ch = codec == "xa2" ? SFXCodec.eaXaV2(d, offset: o, samples: count) : SFXCodec.vag(d, offset: o, samples: count)
            let k = 1 / (32768 * Float(offs.count))
            for i in 0..<count { mono[i] += Float(ch[i]) * k }
        }
        let s = SFXSample(data: mono, rate: rate, loop: le >= 0 ? (ls, min(le, count - 1)) : nil)
        samples[key] = s
        return s
    }

    /// Motor granular (.GIN) ya decodificado.
    func gin(_ path: String) -> GinsuData? {
        lock.lock(); defer { lock.unlock() }
        if let g = ginCache[path] { return g }
        guard let d = file(path), let g = GinsuData(d) else { return nil }
        ginCache[path] = g
        return g
    }

    /// Primer banco de una lista global de audiosystem (skid, nos, roadnoise, wind, misc, stitch, env, fe).
    func globalBank(_ kind: String, _ i: Int = 0) -> String? {
        guard let l = global[kind], i < l.count else { return nil }
        return l[i]
    }
    /// Banco de la lista «misc» por nombre (SIREN_MB, TRAFFIC_MB…).
    func miscBank(_ name: String) -> String? { global["misc"]?.compactMap { $0 }.first { $0.contains(name) } }

    /// Sonidos de un coche (pvehicle) como los elige EAXCar::Attach [D]; nil si no está.
    func carSounds(_ name: String) -> [String: Any]? {
        let k = name.lowercased()
        if let c = cars[k] { return c }
        return GameData.attribAlias[k].flatMap { cars[$0] }
    }
}

// MARK: - Códecs (iguales a tools/src/lib/abk.ts)

enum SFXCodec {
    private static let vagF: [(Int32, Int32)] = [(0, 0), (60, 0), (115, -52), (98, -55), (122, -60)]
    private static let xaT: [Int32] = [0, 240, 460, 392, 0, 0, -208, -220]

    /// PS-ADPCM: 16 B → 28 muestras; la historia guarda la muestra saturada (como la SPU) [I: psx-spx].
    static func vag(_ d: Data, offset: Int, samples: Int) -> [Int16] {
        var out = [Int16](repeating: 0, count: samples)
        d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let b = raw.bindMemory(to: UInt8.self)
            var h1: Int32 = 0, h2: Int32 = 0, n = 0, p = offset
            while n < samples && p + 16 <= b.count {
                let shift = Int32(b[p] & 0x0f), f = vagF[min(4, Int(b[p] >> 4))]
                for i in 0..<28 where n < samples {
                    let byte = b[p + 2 + (i >> 1)]
                    let nib = Int32((i & 1) == 1 ? byte >> 4 : byte & 0x0f)
                    var s = ((nib << 28) >> 28) << 12
                    s = (s >> shift) + ((h1 * f.0 + h2 * f.1) >> 6)
                    s = max(-32768, min(32767, s))
                    out[n] = Int16(s); n += 1; h2 = h1; h1 = s
                }
                p += 16
            }
        }
        return out
    }

    /// EA-XA v2 (mono): tramas de 15 B o 61 B (0xEE + 2 historias + 28 muestras PCM big endian).
    static func eaXaV2(_ d: Data, offset: Int, samples: Int) -> [Int16] {
        var out = [Int16](repeating: 0, count: samples)
        d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let b = raw.bindMemory(to: UInt8.self)
            func be16(_ o: Int) -> Int32 { Int32(Int16(bitPattern: UInt16(b[o]) << 8 | UInt16(b[o + 1]))) }
            var h1: Int32 = 0, h2: Int32 = 0, n = 0, p = offset
            while n < samples && p < b.count {
                let info = b[p]
                if info == 0xee {
                    guard p + 61 <= b.count else { break }
                    h1 = be16(p + 1); h2 = be16(p + 3)
                    for i in 0..<28 where n < samples { out[n] = Int16(be16(p + 5 + 2 * i)); n += 1 }
                    p += 61
                } else {
                    guard p + 15 <= b.count else { break }
                    let c1 = xaT[Int(info >> 4) & 3], c2 = xaT[(Int(info >> 4) & 3) + 4], shift = Int32(info & 0x0f) + 8
                    for i in 0..<28 where n < samples {
                        let byte = b[p + 1 + (i >> 1)]
                        let nib = Int32((i & 1) == 1 ? byte & 0x0f : byte >> 4)
                        var s = (nib << 28) >> shift
                        s = (s + c1 * h1 + c2 * h2) >> 8
                        s = max(-32768, min(32767, s))
                        out[n] = Int16(s); n += 1; h2 = h1; h1 = s
                    }
                    p += 15
                }
            }
        }
        return out
    }
}
