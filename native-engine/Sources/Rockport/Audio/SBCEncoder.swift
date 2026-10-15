// Codificador SBC mínimo (Bluetooth A2DP, especificación pública: A2DP v1.x, apéndice B «SBC»), escrito para este port.
// Lo usa el DualShock 4 por Bluetooth: el PS4 le manda el audio del altavoz en informes HID 0x14/0x15/0x17 con tramas SBC
// de 32 kHz, 16 bloques, 8 subbandas, doble canal, bitpool 25, asignación «loudness» (cabecera 9C 75 19) [I: ver doc 15].
// Solo lo necesario: 8 subbandas, mono / doble canal / estéreo (sin joint), asignación loudness o SNR.
// Verificado decodificando con FFmpeg (`-f sbc`): `Rockport --pad-audio-test` (ver docs/es/15-mandos.md §7).
import Foundation

struct SBCEncoder {
    enum Mode: Int { case mono = 0, dual = 1, stereo = 2 }
    let rate: Int, blocks: Int, mode: Mode, bitpool: Int, snr: Bool
    var channels: Int { mode == .mono ? 1 : 2 }
    let subbands = 8
    private var x: [[Double]]   // 80 muestras de historia por canal

    /// Ventana de análisis de 8 subbandas (tabla de la especificación A2DP; signo alterno por bloques de 16).
    static let proto: [Double] = [
        0.00000000E+00, 1.56575398E-04, 3.43256425E-04, 5.54620202E-04, 8.23919506E-04, 1.13992507E-03, 1.47640169E-03, 1.78371725E-03,
        2.01182542E-03, 2.10371989E-03, 1.99454554E-03, 1.61656283E-03, 9.02154502E-04, -1.78805361E-04, -1.64973098E-03, -3.49717454E-03,
        5.65949473E-03, 8.02941163E-03, 1.04584443E-02, 1.27472335E-02, 1.46525263E-02, 1.59045603E-02, 1.62208471E-02, 1.53184106E-02,
        1.29371806E-02, 8.85757540E-03, 2.92408442E-03, -4.91578024E-03, -1.46404076E-02, -2.61098752E-02, -3.90751381E-02, -5.31873032E-02,
        6.79989431E-02, 8.29847578E-02, 9.75753918E-02, 1.11196689E-01, 1.23264548E-01, 1.33264415E-01, 1.40753505E-01, 1.45389847E-01,
        1.46955068E-01, 1.45389847E-01, 1.40753505E-01, 1.33264415E-01, 1.23264548E-01, 1.11196689E-01, 9.75753918E-02, 8.29847578E-02,
        -6.79989431E-02, -5.31873032E-02, -3.90751381E-02, -2.61098752E-02, -1.46404076E-02, -4.91578024E-03, 2.92408442E-03, 8.85757540E-03,
        1.29371806E-02, 1.53184106E-02, 1.62208471E-02, 1.59045603E-02, 1.46525263E-02, 1.27472335E-02, 1.04584443E-02, 8.02941163E-03,
        -5.65949473E-03, -3.49717454E-03, -1.64973098E-03, -1.78805361E-04, 9.02154502E-04, 1.61656283E-03, 1.99454554E-03, 2.10371989E-03,
        2.01182542E-03, 1.78371725E-03, 1.47640169E-03, 1.13992507E-03, 8.23919506E-04, 5.54620202E-04, 3.43256425E-04, 1.56575398E-04,
    ]
    /// Matriz de análisis M[i][k] = cos((i + 0,5)(k − 4)π/8).
    static let matrix: [[Double]] = (0..<8).map { i in (0..<16).map { k in cos((Double(i) + 0.5) * Double(k - 4) * .pi / 8) } }
    /// Desplazamientos de la asignación «loudness», 8 subbandas, por frecuencia (16 / 32 / 44,1 / 48 kHz).
    static let offset8: [[Int]] = [[-2, 0, 0, 0, 0, 0, 0, 1], [-3, 0, 0, 0, 0, 0, 1, 2], [-4, 0, 0, 0, 0, 0, 1, 2], [-4, 0, 0, 0, 0, 0, 1, 2]]

    init(rate: Int = 32000, blocks: Int = 16, mode: Mode = .dual, bitpool: Int = 25, snr: Bool = false) {
        self.rate = rate; self.blocks = blocks; self.mode = mode; self.bitpool = bitpool; self.snr = snr
        x = Array(repeating: Array(repeating: 0, count: 80), count: mode == .mono ? 1 : 2)
    }

    var samplesPerFrame: Int { blocks * subbands }
    var frameBytes: Int {
        let audioBits = mode == .dual || mode == .mono ? blocks * channels * bitpool : bitpool * blocks
        return 4 + (4 * subbands * channels) / 8 + (audioBits + 7) / 8
    }
    private var freqIndex: Int { [16000: 0, 32000: 1, 44100: 2, 48000: 3][rate] ?? 1 }

    /// Una trama. `pcm[c]` = `samplesPerFrame` muestras del canal c en escala de 16 bits (−32768…32767).
    mutating func encode(_ pcm: [[Float]]) -> [UInt8] {
        let nch = channels, nsb = subbands
        // 1. Banco de filtros de análisis
        var sb = Array(repeating: Array(repeating: Array(repeating: 0.0, count: nsb), count: nch), count: blocks)
        for c in 0..<nch {
            for b in 0..<blocks {
                for i in stride(from: 79, through: 8, by: -1) { x[c][i] = x[c][i - 8] }
                for i in stride(from: 7, through: 0, by: -1) { x[c][i] = Double(pcm[c][b * nsb + (7 - i)]) }
                var y = [Double](repeating: 0, count: 16)
                for i in 0..<16 { var s = 0.0; for j in 0..<5 { s += SBCEncoder.proto[i + 16 * j] * x[c][i + 16 * j] }; y[i] = s }
                for i in 0..<nsb { var s = 0.0; for k in 0..<16 { s += SBCEncoder.matrix[i][k] * y[k] }; sb[b][c][i] = s }
            }
        }
        // 2. Factores de escala: 2^(sf+1) > máx |muestra|
        var scf = Array(repeating: Array(repeating: 0, count: nsb), count: nch)
        for c in 0..<nch { for i in 0..<nsb {
            var m = 0.0; for b in 0..<blocks { m = max(m, abs(sb[b][c][i])) }
            var s = 0; while s < 15 && Double(1 << (s + 1)) <= m { s += 1 }
            scf[c][i] = s
        } }
        // 3. Asignación de bits (por canal en mono/doble; conjunta en estéreo)
        var bits = Array(repeating: Array(repeating: 0, count: nsb), count: nch)
        if mode == .stereo { bits = allocate(scf, joint: true) }
        else { for c in 0..<nch { bits[c] = allocate([scf[c]], joint: false)[0] } }
        // 4. Cabecera, factores de escala y CRC
        var w = BitWriter()
        let b1 = UInt8(freqIndex << 6 | (blocks / 4 - 1) << 4 | mode.rawValue << 2 | (snr ? 1 : 0) << 1 | 1)
        w.put(0x9C, 8); w.put(Int(b1), 8); w.put(bitpool, 8); w.put(0, 8)
        var crcBits = BitWriter(); crcBits.put(Int(b1), 8); crcBits.put(bitpool, 8)
        for c in 0..<nch { for i in 0..<nsb { w.put(scf[c][i], 4); crcBits.put(scf[c][i], 4) } }
        // 5. Cuantización y muestras
        for b in 0..<blocks { for c in 0..<nch { for i in 0..<nsb where bits[c][i] > 0 {
            let levels = Double((1 << bits[c][i]) - 1)
            let q = Int(((sb[b][c][i] / Double(1 << (scf[c][i] + 1))) + 1) * levels / 2)
            w.put(max(0, min(Int(levels), q)), bits[c][i])
        } } }
        var out = w.bytes
        out[3] = SBCEncoder.crc8(crcBits.bytes, bitCount: crcBits.count)
        return out
    }

    /// Asignación de bits (especificación A2DP, apéndice B). `joint` = un bitpool para los dos canales (estéreo).
    private func allocate(_ scf: [[Int]], joint: Bool) -> [[Int]] {
        let nch = scf.count, nsb = subbands
        var need = scf.map { s in (0..<nsb).map { i -> Int in
            if snr { return s[i] }
            if s[i] == 0 { return -5 }
            let l = s[i] - SBCEncoder.offset8[freqIndex][i]
            return l > 0 ? l / 2 : l
        } }
        let maxNeed = need.flatMap { $0 }.max() ?? 0
        var bitcount = 0, slicecount = 0, slice = maxNeed + 1
        repeat {
            slice -= 1; bitcount += slicecount; slicecount = 0
            for c in 0..<nch { for i in 0..<nsb {
                if need[c][i] > slice + 1 && need[c][i] < slice + 16 { slicecount += 1 }
                else if need[c][i] == slice + 1 { slicecount += 2 }
            } }
        } while bitcount + slicecount < bitpool
        if bitcount + slicecount == bitpool { bitcount += slicecount; slice -= 1 }
        var bits = need.map { n in n.map { $0 < slice + 2 ? 0 : min($0 - slice, 16) } }
        // Reparto de lo que sobra (en estéreo, alternando canales por subbanda)
        let order: [(Int, Int)] = (0..<nsb).flatMap { i in (0..<nch).map { c in (c, i) } }
        var k = 0
        while bitcount < bitpool && k < order.count {
            let (c, i) = order[k]
            if bits[c][i] >= 2 && bits[c][i] < 16 { bits[c][i] += 1; bitcount += 1 }
            else if need[c][i] == slice + 1 && bitpool > bitcount + 1 { bits[c][i] = 2; bitcount += 2 }
            k += 1
        }
        k = 0
        while bitcount < bitpool && k < order.count {
            let (c, i) = order[k]
            if bits[c][i] < 16 { bits[c][i] += 1; bitcount += 1 }
            k += 1
        }
        need.removeAll()
        return bits
    }

    /// CRC-8 de SBC: polinomio x⁸ + x⁴ + x³ + x² + 1 (0x1D), valor inicial 0x0F, sobre los bits de la cabecera y los factores de escala.
    static func crc8(_ data: [UInt8], bitCount: Int) -> UInt8 {
        var crc: UInt8 = 0x0F
        for n in 0..<bitCount {
            let bit = (data[n / 8] >> (7 - UInt8(n % 8))) & 1
            let top = (crc >> 7) & 1
            crc <<= 1
            if top ^ bit == 1 { crc ^= 0x1D }
        }
        return crc
    }

    struct BitWriter {
        var bytes: [UInt8] = []
        var count = 0
        mutating func put(_ v: Int, _ n: Int) {
            for k in stride(from: n - 1, through: 0, by: -1) {
                if count % 8 == 0 { bytes.append(0) }
                if (v >> k) & 1 == 1 { bytes[bytes.count - 1] |= UInt8(0x80 >> (count % 8)) }
                count += 1
            }
        }
    }
}
