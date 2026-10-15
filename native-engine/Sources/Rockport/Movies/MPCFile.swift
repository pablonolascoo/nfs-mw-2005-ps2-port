// Películas EA «MPC» del disco (MOVIES\*.MPC), leídas tal cual de la ISO del jugador (doc 22).
//
// Contenedor [V: SLES-53559, comparado con ffmpeg]: bloques seguidos {char tag[4], u32 tamaño LE (incluye los 8 B)}:
//   MPCh  vídeo: UNA imagen MPEG-2 por bloque (el primero lleva la cabecera de secuencia 00 00 01 B3)
//   SCHl  cabecera de audio (GSTR + etiquetas EA: 0x80 revisión 3 → ADPCM R3 a 48 kHz, 0x82 canales, 0x85 nº de muestras)
//   SCCl  nº de bloques de audio · SCDl bloques de audio · SCEl fin
// Audio EA ADPCM «R3» [D: ffmpeg adpcm_ea_r3; V: idéntico a ffmpeg en el lector TS tools/src/lib/mpc.ts]:
//   SCDl = u32 BE nº de muestras · u32 BE desplazamiento de cada canal (relativo al final de la cabecera de (1 + canales) × 4 B)
//   por canal, tramas de 28 muestras: 1 B {coeficiente(4) | desplazamiento(4)} + 14 B de nibbles, o 0xEE + 2 historias BE
//   + 28 muestras PCM BE. La historia de cada canal sigue de un bloque al siguiente.
import Foundation

struct MPCPicture {
    /// Bloque MPCh: desplazamiento de los datos (sin los 8 B de cabecera) y tamaño, dentro de `MPCFile.data`.
    var offset: Int
    var size: Int
    /// 1 = I, 2 = P, 3 = B (picture_coding_type).
    var type: Int
    /// temporal_reference: orden de presentación dentro del GOP.
    var temporalRef: Int
    /// ¿Empieza aquí un GOP (cabecera 00 00 01 B8 en el bloque)?
    var gopStart: Bool
    /// Orden de presentación en toda la película (0, 1, 2…), calculado al leer.
    var pts: Int
}

final class MPCFile {
    let data: Data
    private(set) var pictures: [MPCPicture] = []
    private(set) var audioBlocks: [(offset: Int, size: Int)] = []
    private(set) var width = 0, height = 0, aspectCode = 0
    private(set) var fps = 25.0
    private(set) var sampleRate = 48000, channels = 2, audioCodec = -1, audioSamples = 0
    /// La cabecera de secuencia (para el formato de VideoToolbox).
    private(set) var sequenceHeader: Data?

    var duration: Double { Double(pictures.count) / fps }

    private static let fpsTable: [Double] = [0, 24000.0 / 1001, 24, 25, 30000.0 / 1001, 30, 50, 60000.0 / 1001, 60]

    /// `data` = el archivo MPC completo (normalmente un trozo sin copiar de la ISO mapeada en memoria).
    init(data: Data) throws {
        self.data = data
        try parse()
    }

    private func parse() throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let b = raw.bindMemory(to: UInt8.self)
            let n = b.count
            func tag(_ o: Int) -> String { String(bytes: [b[o], b[o + 1], b[o + 2], b[o + 3]], encoding: .ascii) ?? "????" }
            func u32le(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 }
            guard n >= 8, tag(0) == "MPCh" else { throw NSError(domain: "MPC", code: 1, userInfo: [NSLocalizedDescriptionKey: "no es un MPC (falta MPCh)"]) }
            var o = 0
            while o + 8 <= n {
                let t = tag(o), size = u32le(o + 4)
                guard size >= 8, o + size <= n else { throw NSError(domain: "MPC", code: 2, userInfo: [NSLocalizedDescriptionKey: "bloque \(t) @\(o) de \(size) B fuera del archivo"]) }
                switch t {
                case "MPCh":
                    var pic = MPCPicture(offset: o + 8, size: size - 8, type: 0, temporalRef: 0, gopStart: false, pts: 0)
                    var i = o + 8
                    let end = o + size
                    while i + 6 < end {
                        if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                            let code = b[i + 3]
                            if code == 0xB3, width == 0 {
                                width = Int(b[i + 4]) << 4 | Int(b[i + 5]) >> 4
                                height = (Int(b[i + 5]) & 15) << 8 | Int(b[i + 6])
                                aspectCode = Int(b[i + 7]) >> 4
                                let f = Int(b[i + 7]) & 15
                                fps = f < MPCFile.fpsTable.count && f > 0 ? MPCFile.fpsTable[f] : 25
                                sequenceHeader = data.subdata(in: (o + 8)..<end)
                            } else if code == 0xB8 {
                                pic.gopStart = true
                            } else if code == 0x00 {
                                pic.temporalRef = Int(b[i + 4]) << 2 | Int(b[i + 5]) >> 6
                                pic.type = Int(b[i + 5] >> 3) & 7
                                break
                            }
                            i += 4
                        } else { i += 1 }
                    }
                    pictures.append(pic)
                case "SCHl":
                    let tags = MPCFile.eaTags(b, start: o + 8, end: o + size)
                    audioCodec = tags[0x80] ?? -1
                    sampleRate = tags[0x84] ?? (audioCodec == 3 ? 48000 : 22050)
                    channels = tags[0x82] ?? 1
                    audioSamples = tags[0x85] ?? 0
                case "SCDl":
                    audioBlocks.append((o + 8, size - 8))
                default: break
                }
                o += size
            }
        }
        // Orden de presentación: base del GOP (nº de imágenes antes de él) + temporal_reference [V: doc 22].
        // El GOP empieza en cada cabecera 00 00 01 B8 (estos MPC la traen [V]); si no hubiera, en cada imagen I.
        let useHeaders = pictures.contains { $0.gopStart }
        var gopBase = 0
        for i in pictures.indices {
            if useHeaders ? pictures[i].gopStart : pictures[i].type == 1 { gopBase = i }
            pictures[i].pts = gopBase + pictures[i].temporalRef
        }
    }

    /// Etiquetas EA {tag, n, n bytes BE} desde 0xFD hasta 0xFF (cabecera SCHl «GSTR»).
    private static func eaTags(_ b: UnsafeBufferPointer<UInt8>, start: Int, end: Int) -> [Int: Int] {
        var tags: [Int: Int] = [:]
        var p = start
        while p < end && b[p] != 0xFD { p += 1 }
        guard p < end else { return tags }
        p += 1
        while p + 1 < end {
            let t = Int(b[p]); p += 1
            if t == 0xFF { break }
            if t == 0xFD || t == 0xFC || t == 0xFE { continue }
            let k = Int(b[p]); p += 1
            var v = 0
            for j in 0..<k where p + j < end { v = v << 8 | Int(b[p + j]) }
            p += k
            tags[t] = v
        }
        return tags
    }

    // MARK: Audio EA ADPCM R3

    private static let eaTable: [Int32] = [0, 240, 460, 392, 0, 0, -208, -220, 0, 1, 3, 4, 7, 8, 10, 11, 0, -1, -3, -4]

    /// Decodifica todo el audio → un array Int16 por canal (igual que `decodeMpcAudio` de tools/src/lib/mpc.ts).
    func decodeAudio() -> [[Int16]] {
        let ch = max(1, channels)
        guard !audioBlocks.isEmpty else { return [] }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [[Int16]] in
            let b = raw.bindMemory(to: UInt8.self)
            func u32be(_ o: Int) -> Int { Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3]) }
            func s16be(_ o: Int) -> Int32 { Int32(Int16(bitPattern: UInt16(b[o]) << 8 | UInt16(b[o + 1]))) }
            var total = 0
            for a in audioBlocks { let n = u32be(a.offset); total += n - n % 28 }
            var out = [[Int16]](repeating: [Int16](repeating: 0, count: total), count: ch)
            var cur = [Int32](repeating: 0, count: ch), prev = [Int32](repeating: 0, count: ch)
            var pos = 0
            for a in audioBlocks {
                var n = u32be(a.offset); n -= n % 28
                let base = a.offset + (ch + 1) * 4
                for c in 0..<ch {
                    var p = base + u32be(a.offset + 4 + 4 * c)
                    var s1 = cur[c], s2 = prev[c], w = pos
                    out[c].withUnsafeMutableBufferPointer { o in
                        for _ in 0..<(n / 28) {
                            guard p < b.count else { break }
                            let hdr = b[p]; p += 1
                            if hdr == 0xEE {
                                guard p + 4 + 56 <= b.count else { break }
                                s1 = s16be(p); s2 = s16be(p + 2); p += 4
                                for _ in 0..<28 { o[w] = Int16(s16be(p)); w += 1; p += 2 }
                            } else {
                                let c1 = MPCFile.eaTable[Int(hdr >> 4)], c2 = MPCFile.eaTable[Int(hdr >> 4) + 4]
                                let shift = 20 - Int32(hdr & 15)
                                var byte: Int32 = 0
                                for i in 0..<28 {
                                    let nib: Int32
                                    if i & 1 == 1 { nib = (byte << 28) >> 28 } else { guard p < b.count else { break }; byte = Int32(b[p]); p += 1; nib = (byte << 24) >> 28 }
                                    var s = ((nib << shift) + s1 * c1 + s2 * c2) >> 8
                                    s = max(-32768, min(32767, s))
                                    s2 = s1; s1 = s; o[w] = Int16(s); w += 1
                                }
                            }
                        }
                    }
                    cur[c] = s1; prev[c] = s2
                }
                pos += n
            }
            return out
        }
    }
}
