// Reproducción de una película: carga (ISO → MPC → audio R3 decodificado) en segundo plano, vídeo por VideoToolbox en un
// hilo que va por delante (cola de ~12 imágenes), audio por AVAudioEngine a 48 kHz y sincronía con el reloj del audio
// (la imagen se elige por el reloj; si va retrasada se saltan imágenes, nunca se espera al vídeo).
//
// Sin ventana (`--movie-test`), el reloj lo lleva la prueba: `pullAudio` consume el audio y el reloj avanza con él.
import Foundation
import AVFoundation
import CoreVideo
import os

final class MoviePlayer {
    enum State { case loading, playing, finished, failed }

    let info: MovieInfo
    let name: String
    let volume: Float
    let cues: [(start: Double, end: Double, text: String)]
    /// ¿Se puede saltar? [D: FEMovieScreen MovieData.Bypassable: el logo de EA no]. D-Day: solo tras 5 s [D: MoviePlayer_Bypass].
    let skippable: Bool
    let skipAfter: Double

    private(set) var state: State = .loading
    private(set) var error: String?
    private(set) var mpc: MPCFile?
    private var audio: [[Int16]] = []
    private(set) var audioRate = 48000
    private(set) var fps = 25.0
    private(set) var videoFrames = 0

    // Cola de imágenes (hilo de decodificación → hilo del juego)
    private var lock = os_unfair_lock()
    private var queue: [MPEG2Decoder.Frame] = []
    private var decodeDone = false
    private var stopFlag = false
    private let work = DispatchQueue(label: "rockport.movie", qos: .userInitiated)
    private(set) var decodeErrors = 0
    private(set) var decodedCount = 0

    // Reloj: muestras de audio consumidas
    private var audioPos = 0
    private var started = false
    private var avEngine: AVAudioEngine?
    private var outputLatency = 0.0
    private var wallStart = 0.0
    let realtime: Bool
    /// Multiplicador del volumen (pruebas en tiempo real sin sonido: 0).
    static var gainScale: Float = 1

    // Lo que se ve
    private(set) var current: MPEG2Decoder.Frame?
    // Estadísticas de sincronía
    private(set) var shown = 0, skipped = 0
    private(set) var maxLead = 0.0, maxLag = 0.0, sumAbsOffset = 0.0, samplesOffset = 0
    private var lastShownPTS = -1
    private(set) var ptsOrderOK = true

    init(info: MovieInfo, library: MovieLibrary, realtime: Bool = true) {
        self.info = info
        name = info.name
        volume = library.volume(info)
        cues = library.subtitleCues(info)
        skippable = info.name.uppercased() != "EALOGO"
        skipAfter = ["STORYFMV_RAC01", "STORYFMV_PIN11", "STORYFMV_BUS12", "STORYFMV_CRO06_COH06A", "STORYFMV_RAZ08", "STORYFMV_DDA01"].contains(info.name.uppercased()) ? 5 : 0
        self.realtime = realtime
        let lib = library
        work.async { [weak self] in self?.load(lib) }
    }

    deinit { stop() }

    private func load(_ lib: MovieLibrary) {
        do {
            let m = try lib.open(info)
            guard m.width > 0, !m.pictures.isEmpty else { throw NSError(domain: "Movies", code: 4, userInfo: [NSLocalizedDescriptionKey: "\(info.name): sin vídeo MPEG-2"]) }
            let a = m.decodeAudio()
            let dec = try MPEG2Decoder(m)
            os_unfair_lock_lock(&lock)
            mpc = m; audio = a; audioRate = m.sampleRate; fps = m.fps; videoFrames = m.pictures.count
            os_unfair_lock_unlock(&lock)
            decodeLoop(dec)
        } catch {
            os_unfair_lock_lock(&lock)
            self.error = error.localizedDescription; state = .failed
            os_unfair_lock_unlock(&lock)
        }
    }

    /// Hilo de decodificación: va por delante del reloj hasta 12 imágenes.
    private func decodeLoop(_ dec: MPEG2Decoder) {
        while true {
            os_unfair_lock_lock(&lock)
            let stop = stopFlag, n = queue.count
            os_unfair_lock_unlock(&lock)
            if stop { break }
            if n >= 12 { usleep(realtime ? 3000 : 200); continue }
            let f = dec.nextFrame()
            os_unfair_lock_lock(&lock)
            decodeErrors = dec.decodeErrors; decodedCount = dec.decoded
            if let f { queue.append(f) } else { decodeDone = true }
            os_unfair_lock_unlock(&lock)
            if f == nil { break }
        }
    }

    func stop() {
        os_unfair_lock_lock(&lock); stopFlag = true; os_unfair_lock_unlock(&lock)
        avEngine?.stop(); avEngine = nil
    }

    // MARK: Reloj y audio

    var audioDuration: Double { audio.first.map { Double($0.count) / Double(audioRate) } ?? 0 }
    var videoDuration: Double { Double(videoFrames) / fps }
    var duration: Double { max(audioDuration, videoDuration) }

    /// Tiempo de la película (s) según el audio que ya ha sonado.
    var clock: Double {
        guard started else { return 0 }
        if audio.isEmpty { return CACurrentMediaTimeShim.now() - wallStart }
        os_unfair_lock_lock(&lock); let p = audioPos; os_unfair_lock_unlock(&lock)
        return max(0, Double(p) / Double(audioRate) - (realtime ? outputLatency : 0))
    }

    /// Rellena `n` cuadros estéreo (hilo de audio, o la prueba sin ventana).
    func pullAudio(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        os_unfair_lock_lock(&lock)
        let p0 = started ? audioPos : 0
        if started { audioPos += n }
        os_unfair_lock_unlock(&lock)
        let ch = audio.count
        guard started, ch > 0 else { l.update(repeating: 0, count: n); r.update(repeating: 0, count: n); return }
        let total = audio[0].count, g = volume * MoviePlayer.gainScale / 32768
        for i in 0..<n {
            let k = p0 + i
            if k < total {
                l[i] = Float(audio[0][k]) * g
                r[i] = Float(audio[ch > 1 ? 1 : 0][k]) * g
            } else { l[i] = 0; r[i] = 0 }
        }
    }

    private func startAudio() {
        guard realtime, !audio.isEmpty else { return }
        let e = AVAudioEngine()
        let fmt = AVAudioFormat(standardFormatWithSampleRate: Double(audioRate), channels: 2)!
        let node = AVAudioSourceNode(format: fmt) { [weak self] _, _, frames, abl in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            guard let self, list.count >= 2, let l = list[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            self.pullAudio(l, r, Int(frames))
            return noErr
        }
        e.attach(node)
        e.connect(node, to: e.mainMixerNode, format: fmt)
        do {
            try e.start()
            avEngine = e
            outputLatency = e.outputNode.presentationLatency
        } catch { fputs("Películas: AVAudioEngine no arranca: \(error.localizedDescription)\n", stderr) }
    }

    // MARK: Por fotograma

    /// Avanza: arranca cuando hay imagen, elige la imagen del reloj y termina al acabar vídeo y audio.
    func update() {
        os_unfair_lock_lock(&lock)
        let st = state, err = error, hasFrame = !queue.isEmpty, done = decodeDone
        os_unfair_lock_unlock(&lock)
        if st == .failed { if let err { fputs("Películas: \(name): \(err)\n", stderr) }; error = nil; return }
        if st == .finished { return }
        if st == .loading {
            guard hasFrame || done else { return }
            os_unfair_lock_lock(&lock); state = .playing; started = true; os_unfair_lock_unlock(&lock)
            wallStart = CACurrentMediaTimeShim.now()
            startAudio()
        }
        let t = clock
        // La imagen del reloj: la última con pts ≤ t (las anteriores se saltan)
        os_unfair_lock_lock(&lock)
        var pick: MPEG2Decoder.Frame?
        var dropped = 0
        while let f = queue.first, Double(f.pts) / fps <= t + 0.5 / fps {
            if pick != nil { dropped += 1 }
            pick = queue.removeFirst()
        }
        let empty = queue.isEmpty
        os_unfair_lock_unlock(&lock)
        if let p = pick {
            if p.pts <= lastShownPTS { ptsOrderOK = false }
            lastShownPTS = p.pts
            current = p; shown += 1; skipped += dropped
            let off = Double(p.pts) / fps - t      // + adelantado, − retrasado
            maxLead = max(maxLead, off); maxLag = max(maxLag, -off)
            sumAbsOffset += abs(off); samplesOffset += 1
        }
        if done && empty && t >= duration - 0.02 { finish() }
    }

    func finish() {
        guard state != .finished else { return }
        os_unfair_lock_lock(&lock); state = .finished; os_unfair_lock_unlock(&lock)
        stop()
    }

    var isDone: Bool { state == .finished || state == .failed }

    /// Texto del subtítulo a la hora actual.
    var subtitle: String? {
        guard state == .playing else { return nil }
        let t = clock
        return cues.first { t >= $0.start && t < $0.end }?.text
    }

    func canSkip() -> Bool { skippable && clock >= skipAfter }

    /// Sin ventana: espera a que la decodificación tenga la imagen del reloj actual (la prueba va más rápida que el tiempo real).
    func headlessWait() {
        while true {
            let need = Int(clock * fps) + 1
            os_unfair_lock_lock(&lock)
            let ready = decodeDone || state == .failed || queue.count >= 12 || (queue.last.map { $0.pts >= need } ?? false)
            let loading = state == .loading && queue.isEmpty && !decodeDone && state != .failed
            os_unfair_lock_unlock(&lock)
            if ready && !loading { return }
            usleep(200)
        }
    }

    /// Estadísticas de sincronía para las pruebas.
    var stats: [String: Any] {
        ["movie": name, "videoFrames": videoFrames, "decoded": decodedCount, "decodeErrors": decodeErrors, "shown": shown, "skipped": skipped,
         "videoSeconds": videoDuration, "audioSeconds": audioDuration, "avLengthDiffMs": (audioDuration - videoDuration) * 1000,
         "maxLeadMs": maxLead * 1000, "maxLagMs": maxLag * 1000, "meanAbsOffsetMs": samplesOffset > 0 ? sumAbsOffset / Double(samplesOffset) * 1000 : 0,
         "presentationOrderOK": ptsOrderOK]
    }
}
