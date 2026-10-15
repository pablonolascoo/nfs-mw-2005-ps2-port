// Salida de la música: un AVAudioSourceNode a 32 kHz (la frecuencia de los .MUS [V]) en su propio AVAudioEngine, separado
// del mezclador de efectos (SFXMixer). Cada pista PathFinder (MusicPathFinder) tiene su cadena de trozos sin huecos entre
// ondas (la siguiente se encola antes de que acabe la actual) y su volumen con rampas (fundidos de los eventos).
// Encima: volumen del jugador × nivel del mapa de mezcla × atenuación por voz × paso bajo («pursuit breaker»).
//
// Hilos: el juego encola trozos y cambia ganancias con un cerrojo corto; el hilo de audio copia lo necesario al empezar cada
// bloque. Sin ventana, las pruebas llaman a `render` a mano.
import Foundation
import AVFoundation
import os

/// La cadena de trozos de una pista y su volumen.
final class MusicChannel {
    struct Segment { let id: Int; let node: Int; let pcm: MusicPCM; var pos: Double = 0 }
    fileprivate var lock = os_unfair_lock()
    private var playing: Segment?
    private var queued: [Segment] = []
    private var fading: [(seg: Segment, gain: Float, step: Float)] = []
    private var gain: Float = 1, target: Float = 1, step: Float = 0
    private(set) var outRate: Double = 32000
    // Para el hilo del juego
    private var started: [(id: Int, node: Int)] = []
    private var finishedAll = false

    init(outRate: Double) { self.outRate = outRate }

    func withLock<T>(_ f: () -> T) -> T { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return f() }

    /// Encola una onda tras lo que suene (sin hueco).
    func enqueue(_ s: Segment) { withLock { if playing == nil { playing = s; started.append((s.id, s.node)) } else { queued.append(s) } } }
    /// Quita lo encolado que aún no suena.
    func dropQueued() { withLock { queued.removeAll() } }
    /// Corta lo que suena con un fundido corto (`ms`) y vacía la cola.
    func stop(fadeMs: Double = 25) {
        withLock {
            if let p = playing { fading.append((p, gain, gain / Float(max(1, fadeMs / 1000 * outRate)))) }
            playing = nil; queued.removeAll()
        }
    }
    /// Volumen de la pista (0…1) con rampa de `ms`.
    func setGain(_ g: Float, ms: Double) {
        withLock {
            target = max(0, g)
            if ms <= 0 { gain = target; step = 0 } else { step = (target - gain) / Float(ms / 1000 * outRate) }
        }
    }
    var currentGain: Float { withLock { gain } }

    /// Estado para el juego: la onda que suena, lo que le queda (s), lo encolado y las que empezaron desde la última consulta.
    /// `consume`: devuelve y vacía la lista de ondas empezadas (solo una vez por actualización).
    func poll(consume: Bool = false) -> (playing: (id: Int, node: Int)?, remaining: Double, queued: Int, started: [(id: Int, node: Int)]) {
        withLock {
            let s = consume ? started : []
            if consume { started.removeAll() }
            let rem = playing.map { Double($0.pcm.count) - $0.pos }.map { $0 / Double(playing!.pcm.rate) } ?? 0
            return (playing.map { ($0.id, $0.node) }, rem + queued.reduce(0) { $0 + $1.pcm.seconds }, queued.count, s)
        }
    }

    /// Suma `n` cuadros en l / r (hilo de audio).
    func render(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        // Fundidos de salida (cortes de los eventos «vaciar cola»)
        if !fading.isEmpty {
            for k in fading.indices {
                var f = fading[k]
                let inc = Double(f.seg.pcm.rate) / outRate
                for i in 0..<n {
                    guard f.gain > 0 else { break }
                    let j = Int(f.seg.pos)
                    guard j < f.seg.pcm.count else { f.gain = 0; break }
                    l[i] += Float(f.seg.pcm.left[j]) * (f.gain / 32768); r[i] += Float(f.seg.pcm.right[j]) * (f.gain / 32768)
                    f.seg.pos += inc; f.gain -= f.step
                }
                fading[k] = f
            }
            fading.removeAll { $0.gain <= 0 }
        }
        var i = 0
        while i < n, var s = playing {
            let pcm = s.pcm
            let inc = Double(pcm.rate) / outRate
            let L = pcm.left, R = pcm.right, cnt = pcm.count
            while i < n {
                let j = Int(s.pos)
                if j >= cnt { break }
                let g = gain / 32768
                if inc == 1 {
                    l[i] += Float(L[j]) * g; r[i] += Float(R[j]) * g
                } else {
                    let f = Float(s.pos - Double(j)), j2 = min(cnt - 1, j + 1)
                    l[i] += (Float(L[j]) + (Float(L[j2]) - Float(L[j])) * f) * g
                    r[i] += (Float(R[j]) + (Float(R[j2]) - Float(R[j])) * f) * g
                }
                s.pos += inc
                if step != 0 { gain += step; if (step > 0 && gain >= target) || (step < 0 && gain <= target) { gain = target; step = 0 } }
                i += 1
            }
            if Int(s.pos) >= cnt {
                // Siguiente onda sin hueco
                if queued.isEmpty { playing = nil } else { let nx = queued.removeFirst(); playing = nx; started.append((nx.id, nx.node)) }
            } else { playing = s }
        }
        if step != 0 && playing == nil {   // la rampa sigue aunque no suene nada (fundidos de entrada antes de la onda)
            gain += step * Float(n - i)
            if (step > 0 && gain >= target) || (step < 0 && gain <= target) { gain = target; step = 0 }
        }
    }
}

final class MusicOutput {
    let rate: Double = 32000
    private(set) var channels: [MusicChannel] = []
    private var lock = os_unfair_lock()
    private var avEngine: AVAudioEngine?
    // Ganancia final (juego → hilo de audio)
    private var gainTarget: Float = 0.8
    private var gainLive: Float = 0.8
    private var lowpassHz: Float = 65535
    private var lpL: Float = 0, lpR: Float = 0
    private(set) var paused = false
    private var scratchL = [Float](repeating: 0, count: 4096), scratchR = [Float](repeating: 0, count: 4096)
    /// Pico de la última mezcla (pruebas).
    private(set) var peak: Float = 0

    func makeChannel() -> MusicChannel {
        let c = MusicChannel(outRate: rate)
        os_unfair_lock_lock(&lock); channels.append(c); os_unfair_lock_unlock(&lock)
        return c
    }

    func set(gain: Float, lowpass: Float, paused p: Bool) {
        os_unfair_lock_lock(&lock); gainTarget = gain; lowpassHz = lowpass; paused = p; os_unfair_lock_unlock(&lock)
    }

    func start() {
        guard avEngine == nil else { return }
        let e = AVAudioEngine()
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let node = AVAudioSourceNode(format: fmt) { [weak self] _, _, frames, abl in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            guard let self, list.count >= 2, let l = list[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            var done = 0
            while done < Int(frames) { let k = min(1024, Int(frames) - done); self.render(l + done, r + done, k); done += k }
            return noErr
        }
        e.attach(node)
        e.connect(node, to: e.mainMixerNode, format: fmt)
        do { try e.start(); avEngine = e } catch { fputs("Música: AVAudioEngine no arranca: \(error.localizedDescription)\n", stderr) }
    }
    var isRunning: Bool { avEngine?.isRunning == true }

    /// Mezcla `n` cuadros (hilo de audio o pruebas).
    func render(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        l.update(repeating: 0, count: n); r.update(repeating: 0, count: n)
        os_unfair_lock_lock(&lock)
        let chans = channels, g1 = gainTarget, lp = lowpassHz, p = paused
        os_unfair_lock_unlock(&lock)
        if p { return }   // película en pantalla: la música espera donde estaba (PATH_pause)
        for c in chans { c.render(l, r, n) }
        let g0 = gainLive, dg = (g1 - g0) / Float(n)
        let lpOn = lp < 20000
        let a = lpOn ? 1 - expf(-2 * .pi * max(40, lp) / Float(rate)) : 1
        var g = g0, pk: Float = 0, zl = lpL, zr = lpR
        for i in 0..<n {
            var x = l[i] * g, y = r[i] * g
            if lpOn { zl += a * (x - zl); zr += a * (y - zr); x = zl; y = zr } else { zl = x; zr = y }
            pk = max(pk, abs(x), abs(y))
            l[i] = SFXMixer.soft(x); r[i] = SFXMixer.soft(y)
            g += dg
        }
        lpL = zl; lpR = zr
        gainLive = g1
        peak = pk
    }
}
