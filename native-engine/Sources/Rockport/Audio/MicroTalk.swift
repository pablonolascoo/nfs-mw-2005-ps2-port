// EA MicroTalk (UTK) en bloques EA SCHl: la radio de la policía del disco (COPSPEECH_*.BIG), decodificada dentro de la app.
// Es la misma implementación propia que tools/src/lib/microtalk.ts (allí está la descripción del formato y los créditos).
// Las sumas de productos van con FMA (`addingProduct`), como el vgmstream compilado en arm64: así sale igual muestra a muestra
// (±1 en el 0,8 % de las muestras por redondeo) [V con SLES-53559: `bun src/cli/microtalk-check.ts` y `Rockport --radio-test`].
import Foundation

enum MicroTalk {
    /// Coeficientes de reflexión (simétrica: t[64-i] = -t[i]).
    static let rc: [Float] = {
        let neg: [Float] = [0.996776, 0.990327, 0.983879, 0.977431, 0.970982, 0.964534, 0.958085, 0.951637, 0.930754, 0.904960, 0.879167,
                            0.853373, 0.827579, 0.801786, 0.775992, 0.750198, 0.724405, 0.698611, 0.670635, 0.619048, 0.567460, 0.515873, 0.464286,
                            0.412698, 0.361111, 0.309524, 0.257937, 0.206349, 0.154762, 0.103175, 0.051587]
        var t = [Float](repeating: 0, count: 64)
        for i in 1...31 { t[i] = -neg[i - 1]; t[64 - i] = neg[i - 1] }
        return t
    }()

    /// Libros de códigos del modelo multipulso: [0] normal, [1] pulso grande. 16 filas de 16; cambian la columna 7 y la última.
    static let codebook: [[UInt8]] = {
        func rows(_ base: [UInt8], _ col7: (UInt8, UInt8), _ last: [UInt8]) -> [UInt8] {
            var t = [UInt8](repeating: 0, count: 256)
            for r in 0..<16 {
                for c in 0..<15 { t[r * 16 + c] = base[c] }
                t[r * 16 + 7] = r % 2 == 0 ? col7.0 : col7.1
                t[r * 16 + 15] = last[r]
            }
            return t
        }
        return [rows([4, 6, 5, 9, 4, 6, 5, 0, 4, 6, 5, 10, 4, 6, 5], (13, 14), [17, 21, 18, 25, 17, 22, 18, 0, 17, 21, 18, 26, 17, 22, 18, 2]),
                rows([4, 11, 7, 15, 4, 12, 8, 0, 4, 11, 7, 16, 4, 12, 8], (19, 20), [23, 27, 24, 1, 23, 28, 24, 3, 23, 27, 24, 1, 23, 28, 24, 3])]
    }()

    /// Órdenes: (siguiente modelo, bits, valor del pulso).
    static let commands: [(Int, Int, Float)] = [
        (1, 8, 0), (1, 7, 0), (0, 8, 0), (0, 7, 0), (0, 2, 0), (0, 2, -1), (0, 2, 1), (0, 3, -1), (0, 3, 1),
        (1, 4, -2), (1, 4, 2), (1, 3, -2), (1, 3, 2), (1, 5, -3), (1, 5, 3), (1, 4, -3), (1, 4, 3),
        (1, 6, -4), (1, 6, 4), (1, 5, -4), (1, 5, 4), (1, 7, -5), (1, 7, 5), (1, 6, -5), (1, 6, 5),
        (1, 8, -6), (1, 8, 6), (1, 7, -6), (1, 7, 6),
    ]

    /// Un canal.
    final class Decoder {
        private var data: UnsafeBufferPointer<UInt8> = UnsafeBufferPointer(start: nil, count: 0)
        private var pos = 0, bits: UInt32 = 0, nbits = 0
        private var headerDone = false, reduced = false, threshold = 0
        private var gains = [Float](repeating: 0, count: 64)
        private var rcs = [Float](repeating: 0, count: 12)
        private var hist = [Float](repeating: 0, count: 12)
        private var sub = [Float](repeating: 0, count: 324 + 432)
        private var exc = [Float](repeating: 0, count: 118)
        let pcmBlocks: Bool
        init(pcmBlocks: Bool) { self.pcmBlocks = pcmBlocks }

        func setInput(_ d: UnsafeBufferPointer<UInt8>, offset: Int) { data = d; pos = offset; nbits = 0 }
        @inline(__always) private func byte() -> UInt32 { if pos < data.count { pos += 1; return UInt32(data[pos - 1]) }; return 0 }
        @inline(__always) private func peek(_ n: Int) -> Int { Int(bits & ((1 << n) - 1)) }
        @inline(__always) private func read(_ n: Int) -> Int {
            let v = Int(bits & ((1 << n) - 1))
            bits >>= UInt32(n); nbits -= n
            if nbits < 8 { bits |= byte() << UInt32(nbits); nbits += 8 }
            return v
        }
        private func s16() -> Int { let v = Int(byte() << 8 | byte()); return v >= 0x8000 ? v - 0x10000 : v }

        private func excitation(_ multipulse: Bool, _ start: Int, _ stride: Int) {
            var i = 0
            if multipulse {
                var model = 0
                while i < 108 {
                    let cmd = Int(MicroTalk.codebook[model][peek(8)])
                    let (next, size, value) = MicroTalk.commands[cmd]
                    model = next
                    _ = read(size)
                    if cmd > 3 { exc[start + i] = value; i += stride }
                    else if cmd > 1 {
                        var count = 7 + read(6)
                        if i + count * stride > 108 { count = (108 - i) / stride }
                        while count > 0 { exc[start + i] = 0; i += stride; count -= 1 }
                    } else {
                        var x = 7
                        while read(1) != 0 { x += 1 }
                        if read(1) == 0 { x = -x }
                        exc[start + i] = Float(x); i += stride
                    }
                }
            } else {
                while i < 108 {
                    let c = peek(2)
                    var v: Float = 0, n = 1
                    if c == 1 { v = -2; n = 2 } else if c == 3 { v = 2; n = 2 }
                    _ = read(n)
                    exc[start + i] = v; i += stride
                }
            }
        }

        private func synth(_ offset: Int, _ blocks: Int) {
            var lpc = [Float](repeating: 0, count: 12), t1 = lpc, t2 = lpc
            for i in stride(from: 10, through: 0, by: -1) { t2[i + 1] = rcs[i] }
            t2[0] = 1
            for i in 0..<12 {
                var x = -(rcs[11] * t2[11])
                for j in stride(from: 10, through: 0, by: -1) {
                    x = x.addingProduct(-rcs[j], t2[j])
                    t2[j + 1] = t2[j].addingProduct(x, rcs[j])
                }
                t2[0] = x; t1[i] = x
                for j in 0..<i { x = x.addingProduct(-t1[i - 1 - j], lpc[j]) }
                lpc[i] = x
            }
            var p = 324 + offset
            for _ in 0..<blocks {
                for j in 0..<12 {
                    var x = sub[p]
                    var k = 0
                    while k < j { x = x.addingProduct(lpc[k], hist[k - j + 12]); k += 1 }
                    while k < 12 { x = x.addingProduct(lpc[k], hist[k - j]); k += 1 }
                    hist[11 - j] = x
                    sub[p] = x; p += 1
                }
            }
        }

        /// 432 muestras (float sin redondear).
        func decodeFrame(into out: inout [Float]) {
            let pcm = pcmBlocks ? byte() == 0xEE : false
            if nbits == 0 { bits = byte(); nbits = 8 }
            if !headerDone {
                reduced = read(1) == 1
                let thre = read(4), gain = read(4), mult = read(6)
                threshold = 32 - thre
                gains[0] = 8 * Float(1 + gain)
                let m = Float(1.04) + Float(mult) * Float(0.001)
                for i in 1..<64 { gains[i] = gains[i - 1] * m }
                headerDone = true
            }
            var multipulse = false
            var delta = [Float](repeating: 0, count: 12)
            for i in 0..<12 {
                let idx: Int
                if i == 0 { idx = read(6); if idx < threshold { multipulse = true } }
                else if i < 4 { idx = read(6) }
                else { idx = 16 + read(5) }
                delta[i] = (MicroTalk.rc[idx] - rcs[i]) * 0.25
            }
            for i in 0..<4 {
                let lag = read(8), pv = read(4), gi = read(6)
                let pitchGain = Float(pv) / 15
                var fixedGain = gains[gi]
                if !reduced { excitation(multipulse, 5, 1) }
                else {
                    let align = read(1), zero = read(1)
                    excitation(multipulse, 5 + align, 2)
                    if zero != 0 { for j in 0..<54 { exc[5 + (1 - align) + 2 * j] = 0 } }
                    else {
                        for j in 0..<5 { exc[j] = 0; exc[113 + j] = 0 }
                        let b = 5 + (1 - align)
                        for j in stride(from: 0, to: 108, by: 2) {
                            let a1 = (exc[b + j - 5] + exc[b + j + 5]) * Float(0.01803268)
                            let a2 = (exc[b + j - 3] + exc[b + j + 3]) * Float(0.11459156)
                            let a3 = (exc[b + j - 1] + exc[b + j + 1]) * Float(0.59738597)
                            exc[b + j] = a1 - a2 + a3
                        }
                        fixedGain *= 0.5
                    }
                }
                for j in 0..<108 {
                    let idx = max(0, 108 * i + 216 - lag + j)
                    sub[324 + 108 * i + j] = (pitchGain * sub[idx]).addingProduct(fixedGain, exc[5 + j])
                }
            }
            for i in 0..<324 { sub[i] = sub[432 + i] }
            for i in 0..<4 {
                for j in 0..<12 { rcs[j] += delta[j] }
                synth(12 * i, i < 3 ? 1 : 33)
            }
            if pcmBlocks {
                pos -= 1; nbits = 0
                if pcm {
                    let off = s16(), cnt = s16()
                    if off >= 0 && off <= 432 && cnt >= 0 && cnt <= 432 - off { for i in 0..<cnt { sub[324 + off + i] = Float(s16()) } }
                }
            }
            for i in 0..<432 { out[i] = sub[324 + i] }
        }
    }

    struct Header { var sampleRate = 22050, channels = 1, numSamples = 0, codec2 = -1, version = 0, platform = 0, dataStart = 0 }

    static func parseHeader(_ b: UnsafeBufferPointer<UInt8>) -> Header? {
        guard b.count >= 16, b[0] == 0x53, b[1] == 0x43, b[2] == 0x48, b[3] == 0x6C, b[8] == 0x50, b[9] == 0x54 else { return nil }
        let size = Int(b[4]) | Int(b[5]) << 8 | Int(b[6]) << 16 | Int(b[7]) << 24
        var h = Header(); h.platform = Int(b[10]); h.dataStart = size
        var p = 12, rate = 0
        while p < min(size, b.count) {
            let tag = b[p]; p += 1
            if tag == 0xFF { break }
            if tag == 0xFC || tag == 0xFD || tag == 0xFE { continue }
            let n = Int(b[p]); p += 1
            var v = 0
            for _ in 0..<n where p < b.count { v = v * 256 + Int(b[p]); p += 1 }
            switch tag {
            case 0x80: h.version = v
            case 0x82: h.channels = v
            case 0x84: rate = v
            case 0x85: h.numSamples = v
            case 0xA0: h.codec2 = v
            default: break
            }
        }
        if rate > 0 { h.sampleRate = rate }   // PS2 sin etiqueta → 22 050 Hz
        return h
    }

    /// Decodifica un clip completo y lo mezcla a mono (algunos clips son estéreo). Float −1…1.
    static func decodeMono(_ clip: UnsafeBufferPointer<UInt8>) -> (rate: Int, samples: [Float])? {
        guard let h = parseHeader(clip), h.codec2 == 0x04 || h.codec2 == 0x16, h.channels >= 1 else { return nil }
        let nch = h.channels
        let decs = (0..<nch).map { _ in Decoder(pcmBlocks: h.version >= 3) }
        var out = [Float](repeating: 0, count: max(h.numSamples, 0))
        var frame = [Float](repeating: 0, count: 432)
        var p = h.dataStart, written = [Int](repeating: 0, count: nch)
        func u32(_ o: Int) -> Int { Int(clip[o]) | Int(clip[o + 1]) << 8 | Int(clip[o + 2]) << 16 | Int(clip[o + 3]) << 24 }
        while p + 8 <= clip.count {
            let size = u32(p + 4)
            let isEnd = clip[p] == 0x53 && clip[p + 1] == 0x43 && clip[p + 2] == 0x45 && clip[p + 3] == 0x6C
            if isEnd || size < 8 { break }
            if clip[p] == 0x53, clip[p + 1] == 0x43, clip[p + 2] == 0x44, clip[p + 3] == 0x6C, size >= 0x10 {
                let blockSamples = u32(p + 8)
                for c in 0..<nch {
                    decs[c].setInput(clip, offset: p + 0x0C + 4 * nch + u32(p + 0x0C + 4 * c) + 1)
                    var done = 0
                    while done < blockSamples {
                        decs[c].decodeFrame(into: &frame)
                        let take = min(432, blockSamples - done)
                        for i in 0..<take {
                            let k = written[c] + i
                            if k >= out.count { out.append(0) }
                            let r = max(-32768, min(32767, frame[i].rounded(.toNearestOrAwayFromZero)))
                            out[k] += r / 32768 / Float(nch)
                        }
                        written[c] += take; done += take
                    }
                }
            }
            p += size
        }
        return (h.sampleRate, out)
    }
}
