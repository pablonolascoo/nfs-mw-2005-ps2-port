// Mezclador propio del sonido del juego: un solo AVAudioSourceNode que suma todas las voces en Swift.
// Más barato que un nodo de AVAudioEngine por sonido y funciona igual en tiempo real y en el render sin ventana
// (modo de render manual de AVAudioEngine, `--sound-test`).
//
// Hilos: el juego cambia los parámetros de cada voz (`set`) con un cerrojo corto; el hilo de audio copia los
// parámetros al empezar cada bloque y rampa ganancias y tono dentro del bloque (sin chasquidos).
import Foundation
import AVFoundation
import os

/// Parámetros que el juego fija y el hilo de audio lee.
struct SFXVoiceParams {
    var gainL: Float = 0, gainR: Float = 0
    /// Multiplicador de velocidad de reproducción (tono × efecto Doppler).
    var pitch: Float = 1
    /// Corte del paso bajo de un polo (Hz); ≥ 20 000 = sin filtro.
    var lowpass: Float = 24000
    /// Motor Ginsu: RPM pedidas (frecuencia del .GIN).
    var ginsuFreq: Float = 0
    var stop = false
}

class SFXVoice {
    var params = SFXVoiceParams()
    fileprivate var live = SFXVoiceParams()
    fileprivate var started = false
    fileprivate var lpL: Float = 0, lpR: Float = 0
    /// true cuando ya no suena (una sola vez terminada o parada): el mezclador la quita.
    fileprivate(set) var finished = false
    let tag: String
    init(tag: String) { self.tag = tag }
    /// Suma `n` muestras mono en `mono` con paso de tono `step` (rate·pitch/outRate) y ganancia 1. Devuelve false si terminó.
    func renderMono(_ mono: UnsafeMutablePointer<Float>, _ n: Int, outRate: Double, pitch0: Float, pitch1: Float) -> Bool { false }
    func markFinished() { finished = true }
}

/// Muestra en bucle o de una vez, con retardo opcional (stitches de golpes).
final class SFXSampleVoice: SFXVoice {
    let sample: SFXSample
    let loop: Bool
    private var pos: Double
    private var delay: Int
    init(_ s: SFXSample, loop: Bool, tag: String, startAt: Double = 0, delaySamples: Int = 0) {
        sample = s; self.loop = loop && s.loop != nil; pos = startAt; delay = delaySamples
        super.init(tag: tag)
    }
    override func renderMono(_ mono: UnsafeMutablePointer<Float>, _ n: Int, outRate: Double, pitch0: Float, pitch1: Float) -> Bool {
        let d = sample.data
        guard d.count > 1 else { return false }
        let base = Double(sample.rate) / outRate
        let ls = Double(sample.loop?.0 ?? 0), le = Double(sample.loop?.1 ?? d.count - 1)
        let dp = (pitch1 - pitch0) / Float(max(1, n))
        var p = pitch0
        var i = 0
        if delay > 0 { let k = min(delay, n); delay -= k; i = k; p += dp * Float(k) }
        return d.withUnsafeBufferPointer { b -> Bool in
            while i < n {
                if loop {
                    if pos >= le { pos = ls + (pos - le).truncatingRemainder(dividingBy: max(1, le - ls)) }
                } else if pos >= Double(d.count - 1) { return false }
                let k = Int(pos), f = Float(pos - Double(k))
                let k2 = k + 1 <= Int(le) || !loop ? min(k + 1, d.count - 1) : Int(ls)
                mono[i] += b[k] + (b[k2] - b[k]) * f
                pos += base * Double(p)
                p += dp; i += 1
            }
            return true
        }
    }
}

/// Motor granular: el tono sale del salto de ciclos; `pitch` es SNDpitchmult (por debajo de la RPM mínima del .GIN).
final class SFXGinsuVoice: SFXVoice {
    let voice: GinsuVoice
    private var lastFreq: Float = -1
    init(_ d: GinsuData, tag: String) { voice = GinsuVoice(d); super.init(tag: tag) }
    override func renderMono(_ mono: UnsafeMutablePointer<Float>, _ n: Int, outRate: Double, pitch0: Float, pitch1: Float) -> Bool {
        let f = live.ginsuFreq
        if !voice.synth.started { voice.synth.start(max(f, voice.synth.data.minFrequency)) }
        if f != lastFreq { voice.synth.update(frequency: max(f, voice.synth.data.minFrequency), latencyMs: 60); lastFreq = f }  // GINSU_LATENCY_MS
        let step = Double(voice.synth.data.sampleRate) / outRate * Double((pitch0 + pitch1) * 0.5)
        voice.render(mono, n, step: step, g0: 1, g1: 1)
        return true
    }
}

final class SFXMixer {
    let outRate: Double
    private var voices: [SFXVoice] = []
    private var lock = os_unfair_lock()
    /// Volumen general (ajuste del jugador) y silencio total (pausa).
    var master: Float = 1
    var muted = false
    private var liveMaster: Float = 1
    private var scratch = [Float](repeating: 0, count: 4096)
    private var news: [SFXVoiceParams] = []      // reservado: el hilo de audio no reserva memoria en cada bloque
    /// Pico de la última mezcla (pruebas).
    private(set) var peak: Float = 0

    init(outRate: Double) { self.outRate = outRate }

    func add(_ v: SFXVoice) { os_unfair_lock_lock(&lock); voices.append(v); os_unfair_lock_unlock(&lock) }
    func remove(_ v: SFXVoice) { os_unfair_lock_lock(&lock); v.params.stop = true; os_unfair_lock_unlock(&lock) }
    /// Cambia los parámetros de varias voces de una vez.
    func withLock(_ f: () -> Void) { os_unfair_lock_lock(&lock); f(); os_unfair_lock_unlock(&lock) }
    var voiceCount: Int { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return voices.count }

    /// Mezcla `n` cuadros estéreo (no intercalados) en l / r.
    func render(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        l.update(repeating: 0, count: n); r.update(repeating: 0, count: n)
        os_unfair_lock_lock(&lock)
        voices.removeAll { $0.finished || ($0.params.stop && $0.live.gainL == 0 && $0.live.gainR == 0) }
        let list = voices
        news.removeAll(keepingCapacity: true)
        if news.capacity < list.count + 64 { news.reserveCapacity(list.count + 64) }
        for v in list { var p = v.params; if p.stop { p.gainL = 0; p.gainR = 0 }; news.append(p) }
        let m = muted ? 0 : master
        os_unfair_lock_unlock(&lock)
        if scratch.count < n { scratch = [Float](repeating: 0, count: n) }
        let fs = Float(outRate)
        scratch.withUnsafeMutableBufferPointer { sb in
            let mono = sb.baseAddress!
            for (k, v) in list.enumerated() {
                let a = v.started ? v.live : news[k], b = news[k]
                v.live = b; v.started = true
                if a.gainL == 0 && a.gainR == 0 && b.gainL == 0 && b.gainR == 0 && !(v is SFXGinsuVoice) {
                    if b.stop { v.markFinished() }
                    // Las voces calladas también avanzan (para que el bucle no empiece siempre igual): solo las de una vez
                    continue
                }
                mono.update(repeating: 0, count: n)
                if !v.renderMono(mono, n, outRate: outRate, pitch0: a.pitch, pitch1: b.pitch) { v.markFinished() }
                // Paso bajo de un polo (filtro por distancia / de la mezcla)
                let lpOn = b.lowpass < 19000
                let alpha = lpOn ? 1 - expf(-2 * .pi * max(40, b.lowpass) / fs) : 1
                let dgl = (b.gainL - a.gainL) / Float(n), dgr = (b.gainR - a.gainR) / Float(n)
                var gl = a.gainL, gr = a.gainR, z = v.lpL
                for i in 0..<n {
                    var x = mono[i]
                    if lpOn { z += alpha * (x - z); x = z }
                    l[i] += x * gl; r[i] += x * gr
                    gl += dgl; gr += dgr
                }
                v.lpL = z
                if b.stop { v.markFinished() }
            }
        }
        // Volumen general con rampa y limitador suave (tanh) para que nunca sature
        let dm = (m - liveMaster) / Float(n)
        var g = liveMaster, pk: Float = 0
        for i in 0..<n {
            pk = max(pk, abs(l[i]), abs(r[i]))           // pico antes del volumen general (diagnóstico)
            l[i] = SFXMixer.soft(l[i] * g); r[i] = SFXMixer.soft(r[i] * g)
            g += dm
        }
        liveMaster = m
        peak = pk
    }

    @inline(__always) static func soft(_ x: Float) -> Float { abs(x) < 0.8 ? x : (x > 0 ? 1 : -1) * (0.8 + 0.2 * tanhf((abs(x) - 0.8) / 0.2)) }

    /// Nodo para AVAudioEngine (estéreo no intercalado a `outRate`).
    func makeNode() -> AVAudioSourceNode {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: outRate, channels: 2)!
        return AVAudioSourceNode(format: fmt) { [weak self] _, _, frames, abl in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            guard let self, list.count >= 2, let l = list[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            var done = 0
            let total = Int(frames)
            while done < total {
                let k = min(1024, total - done)
                self.render(l + done, r + done, k)
                done += k
            }
            return noErr
        }
    }
}
