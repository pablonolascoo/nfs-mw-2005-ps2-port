// Motor granular «Ginsu» del juego, portado línea a línea [D: EAXSound/Ginsu/ginsudata.cpp, ginsusynth.cpp].
//
// Un .GIN es una grabación de un motor subiendo (o bajando) de vueltas, cortada en «ciclos» (dos vueltas del cigüeñal)
// con una tabla RPM → posición. El sintetizador reproduce paquetes de 11 ms y, entre paquete y paquete, salta hacia
// delante o hacia atrás un número entero de ciclos para acercarse a la posición de las RPM pedidas, con un fundido de 0,5 ms.
// Así el tono sale de la grabación real a cualquier régimen, sin cambiar la velocidad de reproducción.
// La frecuencia que se pide son RPM: GetCurrentPitch() × 120 = RPM (un ciclo = 2 vueltas) [D: CARSFX_Engine.cpp].
import Foundation

/// GinsuSynthData: cabecera, tablas y muestras ya decodificadas (EA-XAS en coma flotante, convertsample → 16 bits).
final class GinsuData {
    let minFrequency: Float, maxFrequency: Float
    let segCount: Int, cycleCount: Int, sampleCount: Int, sampleRate: Int
    let freqPos: [Int32], cyclePos: [Int32]
    let samples: [Int16]
    let minPeriod: Float

    init?(_ d: Data) {
        guard d.count > 0x20, d[d.startIndex] == 0x47, d[d.startIndex + 1] == 0x6e, d[d.startIndex + 2] == 0x73,
              d[d.startIndex + 3] == 0x75, d[d.startIndex + 4] == 0x32 else { return nil }   // "Gnsu" "2"
        func i32(_ o: Int) -> Int32 { d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: Int32.self) } }
        func f32(_ o: Int) -> Float { Float(bitPattern: UInt32(bitPattern: i32(o))) }
        minFrequency = f32(0x08); maxFrequency = f32(0x0c)
        segCount = Int(i32(0x10)); cycleCount = Int(i32(0x14)); sampleCount = Int(i32(0x18)); sampleRate = Int(i32(0x1c))
        guard segCount >= 0, cycleCount >= 1, sampleCount > 0, sampleRate > 0 else { return nil }
        var p = 0x20
        var fp = [Int32](), cp = [Int32]()
        for _ in 0...segCount { fp.append(i32(p)); p += 4 }
        for _ in 0...cycleCount { cp.append(i32(p)); p += 4 }
        freqPos = fp; cyclePos = cp
        guard p + (sampleCount + 31) / 32 * 19 <= d.count else { return nil }
        var mp = Float(sampleCount)
        for i in 0..<cycleCount { mp = min(mp, Float(cp[i + 1] - cp[i])) }
        minPeriod = mp
        samples = GinsuData.decode(d, offset: p, count: sampleCount)
    }

    private static let filt0: [Float] = [0, 0.9375, 1.796875, 1.53125]
    private static let filt1: [Float] = [0, 0, -0.8125, -0.859375]

    /// DecodeBlock + GetSamples: bloques de 19 B → 32 muestras en float, salida con convertsample (trunca y satura).
    static func decode(_ d: Data, offset: Int, count: Int) -> [Int16] {
        var out = [Int16](repeating: 0, count: count)
        d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let b = raw.bindMemory(to: UInt8.self)
            var s = [Float](repeating: 0, count: 32)
            var k = 0
            while 32 * k < count {
                let o = offset + 19 * k
                s[0] = Float(Int(b[o] & 0xf0) + Int(Int8(bitPattern: b[o + 1])) * 256)
                s[1] = Float(Int(b[o + 2] & 0xf0) + Int(Int8(bitPattern: b[o + 3])) * 256)
                let fi = Int(b[o] & 0x0f), f0 = fi < 4 ? filt0[fi] : 0, f1 = fi < 4 ? filt1[fi] : 0
                let shift = Int(b[o + 2] & 0x0f)
                let step: Float = shift <= 12 ? Float(4096 >> shift) : 0
                for i in 0..<15 {
                    let byte = b[o + 4 + i]
                    let n0 = Float(Int(Int8(bitPattern: byte) >> 4)), n1 = Float(Int(Int8(bitPattern: byte << 4) >> 4))
                    let j = 2 + 2 * i
                    s[j] = n0 * step + f0 * s[j - 1] + f1 * s[j - 2]
                    s[j + 1] = n1 * step + f0 * s[j] + f1 * s[j - 1]
                }
                for i in 0..<32 where 32 * k + i < count {
                    let v = Int(s[i])   // static_cast<int> trunca
                    out[32 * k + i] = Int16(v >= 0x8000 ? 0x7fff : v < -0x8000 ? -0x8000 : v)
                }
                k += 1
            }
        }
        return out
    }

    // MARK: Tablas [D: ginsudata.cpp]

    @inline(__always) static func intRound(_ x: Float) -> Int { 0 < x ? Int(x + 0.5) : Int(x - 0.5) }
    @inline(__always) static func intCeil(_ x: Float) -> Int {
        if 0 < x { let i = Int(x); return Float(i) == x ? i : i + 1 }
        return Int(x)
    }
    @inline(__always) static func intFloor(_ x: Float) -> Int {
        if 0 <= x { return Int(x) }
        let i = Int(x); return Float(i) == x ? i : i - 1
    }

    func frequencyToSample(_ freq: Float) -> Int {
        if segCount < 1 { return 0 }
        if freq <= minFrequency { return Int(freqPos[0]) }
        if freq >= maxFrequency { return Int(freqPos[segCount]) }
        let seg = Float(segCount) * (freq - minFrequency) / (maxFrequency - minFrequency)
        let i = GinsuData.intFloor(seg), a = seg - Float(i)
        return GinsuData.intRound(Float(freqPos[i]) + a * Float(freqPos[i + 1] - freqPos[i]))
    }

    func cycleToSample(_ cycle: Float) -> Int {
        if cycleCount < 1 { return 0 }
        if cycle <= 0 { return Int(cyclePos[0]) }
        if cycle >= Float(cycleCount) { return Int(cyclePos[cycleCount]) }
        let i = GinsuData.intFloor(cycle), a = cycle - Float(i)
        return GinsuData.intRound(Float(cyclePos[i]) + a * Float(cyclePos[i + 1] - cyclePos[i]))
    }

    func cyclePeriod(_ cycleIn: Float) -> Float {
        if cycleCount < 1 { return 0 }
        var cycle = cycleIn
        var i = GinsuData.intFloor(cycle)
        let startPeriod: Float, endPeriod: Float
        if i < 1 {
            if i < 0 { cycle = 0; i = 0 }
            startPeriod = Float(cyclePos[1] - cyclePos[0])
            endPeriod = Float(cyclePos[min(2, cycleCount)] - cyclePos[0]) * 0.5
        } else if i >= cycleCount - 1 {
            if i >= cycleCount { i = cycleCount - 1; cycle = Float(cycleCount) }
            startPeriod = Float(cyclePos[cycleCount] - cyclePos[cycleCount - 2]) * 0.5
            endPeriod = Float(cyclePos[cycleCount] - cyclePos[cycleCount - 1])
        } else {
            startPeriod = Float(cyclePos[i + 1] - cyclePos[i - 1]) * 0.5
            endPeriod = Float(cyclePos[i + 2] - cyclePos[i]) * 0.5
        }
        let a = cycle - Float(i)
        return startPeriod + a * (endPeriod - startPeriod)
    }

    func sampleToCycle(_ sample: Int) -> Float {
        if cycleCount <= 0 { return 0 }
        if sample <= Int(cyclePos[0]) { return 0 }
        if sample >= Int(cyclePos[cycleCount]) { return Float(cycleCount) }
        var low = 0, high = cycleCount, guess = 0
        var guard_ = 0
        while guard_ < 64 {
            guard_ += 1
            while guard_ < 64 {
                guard_ += 1
                guess = low + GinsuData.intFloor(Float(sample - Int(cyclePos[low])) / Float(cyclePos[high] - cyclePos[low]) * Float(high - low))
                guess = max(0, min(cycleCount - 1, guess))
                if sample >= Int(cyclePos[guess]) { break }
                let newlow = guess - GinsuData.intCeil(Float(Int(cyclePos[guess]) - sample) / minPeriod)
                high = guess
                if newlow > low { low = newlow }
            }
            if sample < Int(cyclePos[guess + 1]) { break }
            let newhigh = guess + GinsuData.intCeil(Float(sample - Int(cyclePos[guess])) / minPeriod) + 1
            low = guess + 1
            if newhigh < high { high = newhigh }
        }
        let s1 = Float(cyclePos[guess]), s2 = Float(cyclePos[guess + 1])
        return (Float(sample) - s1) / (s2 - s1) + Float(guess)
    }

    /// GetSamples: false (y no toca `dest`) si el tramo se sale de la grabación.
    @discardableResult
    func getSamples(_ start: Int, _ n: Int, into dest: UnsafeMutablePointer<Int16>) -> Bool {
        if start < 0 || start + n - 1 >= sampleCount || n <= 0 { return n <= 0 }
        samples.withUnsafeBufferPointer { src in dest.update(from: src.baseAddress! + start, count: n) }
        return true
    }

    /// RPM de cada ciclo (120·rate/periodo), para las pruebas.
    var cycleRPM: (first: Float, last: Float) {
        (120 * Float(sampleRate) / Float(cyclePos[1] - cyclePos[0]), 120 * Float(sampleRate) / Float(cyclePos[cycleCount] - cyclePos[cycleCount - 1]))
    }
}

/// GinsuSynthesis: genera paquetes de 11 ms a la frecuencia del .GIN (32 kHz). Se llama desde el hilo de audio.
final class GinsuSynth {
    let data: GinsuData
    let packetSize: Int, noJumpSize: Int, overlapSize: Int
    private var playbackPos = 0, currentPos = 0, targetPos = 0
    private var packetCountdown = 1, noJumpRemaining = 0
    private var currentCycle: Float = 0
    private var packet: [Int16]
    private var buff: [Int16]
    private(set) var started = false

    static let noJumpDuration: Float = 0.011, packetDuration: Float = 0.011, overlapDuration: Float = 0.0005

    init(_ d: GinsuData) {
        data = d
        noJumpSize = GinsuData.intRound(Float(d.sampleRate) * GinsuSynth.noJumpDuration)
        packetSize = GinsuData.intRound(Float(d.sampleRate) * GinsuSynth.packetDuration)
        overlapSize = GinsuData.intRound(Float(d.sampleRate) * GinsuSynth.overlapDuration)
        packet = [Int16](repeating: 0, count: packetSize + overlapSize + 8)
        buff = [Int16](repeating: 0, count: max(256, overlapSize))
    }

    /// StartSynthesis(startFreq).
    func start(_ freq: Float) {
        playbackPos = data.frequencyToSample(freq)
        packetCountdown = 1
        noJumpRemaining = noJumpSize
        currentPos = playbackPos; targetPos = playbackPos
        currentCycle = data.sampleToCycle(playbackPos)
        started = true
    }

    /// UpdateFrequency(targetFreq, latency ms): el cambio se reparte en floor(latencia/11 ms)+1 paquetes.
    func update(frequency: Float, latencyMs: Float) {
        targetPos = data.frequencyToSample(frequency)
        packetCountdown = GinsuData.intFloor(latencyMs * 0.09090909) + 1
    }

    /// GetCurrentPitch(): ciclos por segundo de la posición actual (× 120 = RPM).
    var currentPitch: Float { Float(data.sampleRate) / data.cyclePeriod(currentCycle + 0.5) }

    /// HandlePacketRelease: escribe el siguiente paquete en `out` y devuelve cuántas muestras tiene.
    func nextPacket(_ out: inout [Int16]) -> Int {
        let d = data
        currentCycle = d.sampleToCycle(currentPos)
        let change = Float(targetPos - currentPos) / Float(packetCountdown)
        var jumpTime: Float = 0
        var jumpDist = 0
        if noJumpRemaining < packetSize {
            let playbackCycle = d.sampleToCycle(playbackPos)
            let playbackRate = Float(packetSize) / d.cyclePeriod(playbackCycle)
            let currentRate = change / d.cyclePeriod(currentCycle)
            let posDiff = currentCycle - playbackCycle
            let rateDiff = currentRate - playbackRate
            let nojumpTime = Float(noJumpRemaining) / Float(packetSize)
            let nojumpDist = posDiff + rateDiff * nojumpTime
            let packetDist = posDiff + rateDiff
            if GinsuData.intFloor(nojumpDist) != GinsuData.intFloor(packetDist) {
                jumpDist = nojumpDist < packetDist ? GinsuData.intCeil(nojumpDist) : GinsuData.intFloor(nojumpDist)
                jumpTime = (Float(jumpDist) - posDiff) / rateDiff
            } else {
                let maxDist = Float(GinsuData.intCeil(abs(rateDiff * 0.99999994)))
                if abs(nojumpDist) > maxDist {
                    jumpTime = nojumpTime
                    jumpDist = nojumpDist < 0 ? GinsuData.intCeil(nojumpDist) : GinsuData.intFloor(nojumpDist)
                }
            }
        }
        if jumpDist == 0 { jumpTime = 1 }
        var sampleCount = max(0, min(packetSize, GinsuData.intRound(jumpTime * Float(packetSize))))
        if out.count < packetSize + overlapSize + 8 { out = [Int16](repeating: 0, count: packetSize + overlapSize + 8) }
        out.withUnsafeMutableBufferPointer { o in
            let base = o.baseAddress!
            if !d.getSamples(playbackPos, sampleCount, into: base) { base.update(repeating: 0, count: sampleCount) }
            playbackPos += sampleCount
            noJumpRemaining = max(0, noJumpRemaining - sampleCount)
            if jumpDist != 0 {
                let dest = base + sampleCount
                if !d.getSamples(playbackPos, overlapSize, into: dest) { dest.update(repeating: 0, count: overlapSize) }
                let cycle = d.sampleToCycle(playbackPos)
                playbackPos = d.cycleToSample(cycle + Float(jumpDist))
                buff.withUnsafeMutableBufferPointer { bb in
                    if !d.getSamples(playbackPos, overlapSize, into: bb.baseAddress!) { bb.baseAddress!.update(repeating: 0, count: overlapSize) }
                    var blend: Float = 0
                    let blendstep = 1 / Float(overlapSize)
                    for i in 0..<overlapSize {
                        let val = Float(dest[i]) + blend * Float(Int(bb[i]) - Int(dest[i]))
                        dest[i] = Int16(clamping: GinsuData.intRound(val))
                        blend += blendstep
                    }
                }
                sampleCount += overlapSize
                playbackPos += overlapSize
                let count = packetSize - sampleCount
                noJumpRemaining = noJumpSize - overlapSize
                if count > 0 {
                    if !d.getSamples(playbackPos, count, into: base + sampleCount) { (base + sampleCount).update(repeating: 0, count: count) }
                    sampleCount = packetSize
                    playbackPos += count
                    noJumpRemaining -= count
                }
            }
        }
        currentPos = GinsuData.intRound(Float(currentPos) + change)
        if packetCountdown > 1 { packetCountdown -= 1 }
        return sampleCount
    }
}

/// Voz que reproduce un GinsuSynth a la frecuencia de salida: cola de paquetes + remuestreo lineal × multiplicador de tono
/// (SNDpitchmult: fPitchBelowMinFreq × PitchMultipli). Todo en el hilo de audio.
final class GinsuVoice {
    let synth: GinsuSynth
    private var pkt: [Int16]
    private var pktLen = 0, pktPos = 0
    private var frac: Double = 0
    private var prev: Float = 0, cur: Float = 0

    init(_ d: GinsuData) { synth = GinsuSynth(d); pkt = [Int16](repeating: 0, count: synth.packetSize + synth.overlapSize + 8) }

    @inline(__always) private func pull() -> Float {
        if pktPos >= pktLen { pktLen = synth.nextPacket(&pkt); pktPos = 0; if pktLen == 0 { return 0 } }
        let v = Float(pkt[pktPos]) / 32768
        pktPos += 1
        return v
    }

    /// Suma `n` muestras mono en `out` con ganancia lineal de g0 a g1 y paso de remuestreo `step` (= rate·pitch/outRate).
    func render(_ out: UnsafeMutablePointer<Float>, _ n: Int, step: Double, g0: Float, g1: Float) {
        guard synth.started else { return }
        let dg = (g1 - g0) / Float(max(1, n))
        var g = g0
        for i in 0..<n {
            frac += step
            while frac >= 1 { frac -= 1; prev = cur; cur = pull() }
            out[i] += (prev + (cur - prev) * Float(frac)) * g
            g += dg
        }
    }
}
