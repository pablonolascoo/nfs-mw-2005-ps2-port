// Radio de la policía: frases del disco con sonido de escáner, por el altavoz del mando si se puede.
//
// Salida, por orden (ajuste "policeRadio.output" = auto):
//   1. DualSense / DualShock 4 por Bluetooth → informes HID con Opus / SBC (PadBluetoothAudio.swift) [sin probar con hardware]
//   2. DualSense / DualShock 4 por USB → su dispositivo de audio de CoreAudio (AudioDevices.swift)
//   3. Altavoces del Mac (salida por defecto)
// Siempre con filtro de radio: paso banda 300–3400 Hz, saturación suave, siseo y «chasquidos» de squelch al abrir y cerrar.
// Ajustes en settings.json → "policeRadio": { "enabled": true, "output": "auto|pad|mac", "volume": 0.8, "ambient": true }.
// Al arrancar: --radio-out auto|pad|mac|off  ·  --radio-log (escribe cada frase en la consola).
import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

final class PoliceRadio {
    static let shared = PoliceRadio()

    struct Settings: Codable { var enabled = true; var output = "auto"; var volume: Float = 0.8; var ambient = true }
    private(set) var settings = Settings()
    private(set) var library: RadioLibrary?
    private var triedRoot: URL?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var engineDevice: AudioDeviceID = 0
    private(set) var route = "ninguna"
    private var busyUntil: Double = 0
    private var currentPriority = 0
    var rng = SplitMix(seed: UInt64(Date().timeIntervalSince1970 * 1000))
    let log: Bool
    /// Sin ventana (pruebas): no suena nada, solo se escribe.
    var silent = false
    private let work = DispatchQueue(label: "rockport.radio", qos: .userInitiated)

    private init() {
        let a = CommandLine.arguments
        log = a.contains("--radio-log") || ProcessInfo.processInfo.environment["ROCKPORT_RADIO_LOG"] != nil
        if let d = try? Data(contentsOf: LightBar.settingsURL),
           let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let r = root["policeRadio"],
           let raw = try? JSONSerialization.data(withJSONObject: r), let s = try? JSONDecoder().decode(Settings.self, from: raw) { settings = s }
        if let i = a.firstIndex(of: "--radio-out"), i + 1 < a.count {
            if a[i + 1] == "off" { settings.enabled = false } else { settings.output = a[i + 1] }
        }
    }

    // MARK: Ajustes (para el menú de opciones)

    func setEnabled(_ on: Bool) { settings.enabled = on; save() }
    func setOutput(_ o: String) { settings.output = o; engine?.stop(); engine = nil; save() }
    func setVolume(_ v: Float) { settings.volume = max(0, min(1, v)); PadBluetoothAudio.shared.volume = settings.volume; save() }

    private func save() {
        let url = LightBar.settingsURL
        var root = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        root["policeRadio"] = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))) ?? [:]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    // MARK: Datos

    /// Carga radio/ de la carpeta del disco (una vez).
    func attach(root: URL) {
        guard triedRoot != root else { return }
        triedRoot = root
        library = RadioLibrary(root: root)
        if let l = library { print("Radio de la policía: \(l.index.clips.count) clips (\(l.lang)), \(l.index.events.count) eventos") }
        else if log { print("Radio de la policía: no hay \(root.path)/radio (vuelve a convertir el disco)") }
        if !silent { PadBluetoothAudio.shared.volume = settings.volume; PadBluetoothAudio.shared.start() }
    }

    var isBusy: Bool { CACurrentMediaTimeShim.now() < busyUntil }

    // MARK: Hablar

    /// Dice una línea del evento `event` si la radio está libre (o si su prioridad es mayor que la que suena).
    /// `params`: nº de parámetro del Csis::*Struct → índice de valor (ver RadioLibrary). Devuelve true si se dice.
    @discardableResult
    /// `after`: respuesta encadenada (p. ej. la central contestando): suena cuando acabe lo que está sonando.
    func say(_ event: String, voice: Int, params: [Int: Int] = [:], priority: Int = 1, after: Bool = false) -> Bool {
        guard settings.enabled, let lib = library else { return false }
        let now = CACurrentMediaTimeShim.now()
        if !after && now < busyUntil && priority <= currentPriority { return false }
        guard let clips = lib.line(event, voice: voice, params: params, rng: &rng) else { return false }
        let dur = clips.reduce(0.0) { $0 + Double(lib.index.clips[$1][2]) / Double(lib.index.sampleRate) } + 0.35
        let delay = after ? max(0, busyUntil - now - 0.3) : 0
        busyUntil = now + delay + dur + 0.6; currentPriority = priority
        if log { print(String(format: "radio: %@ (voz %d) → clips %@ · %.1f s", event, voice, clips.map(String.init).joined(separator: ","), dur)) }
        if silent { return true }
        work.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            var r = SplitMix(seed: UInt64(clips.first ?? 1) &* 0x9E37_79B9 &+ UInt64(now * 1000))   // propio de este hilo
            let pcm = RadioDSP.transmission(clips.map { lib.samples($0) }, rate: lib.index.sampleRate, rng: &r)
            self.output(pcm)
        }
        return true
    }

    /// Para pruebas y para el menú: la cadena de radio completa de una línea, a 48 kHz.
    func render(_ event: String, voice: Int, params: [Int: Int] = [:]) -> [Float]? {
        guard let lib = library, let clips = lib.line(event, voice: voice, params: params, rng: &rng) else { return nil }
        return RadioDSP.transmission(clips.map { lib.samples($0) }, rate: lib.index.sampleRate, rng: &rng)
    }

    // MARK: Salida

    private func output(_ pcm48: [Float]) {
        let want = settings.output
        if want != "mac", PadBluetoothAudio.shared.available {
            route = "mando por Bluetooth (\(PadBluetoothAudio.shared.pads.first?.kind.rawValue ?? ""))"
            PadBluetoothAudio.shared.play(pcm48)
            return
        }
        let dev: AudioOutputDevice? = want == "mac" ? nil : AudioDevices.controllerSpeaker()
        playLocal(pcm48, device: dev)
    }

    private func playLocal(_ pcm48: [Float], device: AudioOutputDevice?) {
        let devID = device?.id ?? 0
        if engine == nil || devID != engineDevice {
            engine?.stop()
            let e = AVAudioEngine(), p = AVAudioPlayerNode()
            e.attach(p)
            if devID != 0, let unit = e.outputNode.audioUnit {
                var id = devID
                let st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
                if st != noErr { fputs("Radio: no se pudo usar \(device!.name) (\(st)); sale por el Mac\n", stderr) }
            }
            let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
            e.connect(p, to: e.mainMixerNode, format: fmt)
            do { try e.start() } catch { fputs("Radio: AVAudioEngine no arranca: \(error.localizedDescription)\n", stderr); engine = nil; return }
            p.play()
            engine = e; player = p; engineDevice = devID
            route = device.map { "altavoz del mando por USB (\($0.name))" } ?? "altavoces del Mac"
            if log { print("radio: salida → \(route)") }
        }
        guard let p = player, let buf = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!,
                                                         frameCapacity: AVAudioFrameCount(pcm48.count)) else { return }
        buf.frameLength = AVAudioFrameCount(pcm48.count)
        let v = settings.volume
        for c in 0..<2 { let ch = buf.floatChannelData![c]; for i in 0..<pcm48.count { ch[i] = pcm48[i] * v } }
        p.scheduleBuffer(buf, completionHandler: nil)
    }
}

/// Sonido de escáner de policía [diseño propio]: el disco ya trae voces «de radio»; esto añade el canal.
enum RadioDSP {
    struct Biquad {
        var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
        var z1: Float = 0, z2: Float = 0
        static func make(_ type: String, f: Double, q: Double, fs: Double) -> Biquad {
            let w = 2 * Double.pi * f / fs, al = sin(w) / (2 * q), c = cos(w)
            let a0 = 1 + al
            if type == "hp" {
                return Biquad(b0: Float((1 + c) / 2 / a0), b1: Float(-(1 + c) / a0), b2: Float((1 + c) / 2 / a0), a1: Float(-2 * c / a0), a2: Float((1 - al) / a0))
            }
            return Biquad(b0: Float((1 - c) / 2 / a0), b1: Float((1 - c) / a0), b2: Float((1 - c) / 2 / a0), a1: Float(-2 * c / a0), a2: Float((1 - al) / a0))
        }
        mutating func run(_ x: Float) -> Float {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    /// Clips del disco → una transmisión a 48 kHz: squelch de apertura, voz filtrada, cola de ruido al soltar.
    static func transmission(_ clips: [[Float]], rate: Int, rng: inout SplitMix) -> [Float] {
        let fs = 48000
        var voice: [Float] = []
        for (k, c) in clips.enumerated() {
            voice += Resample.rate(c, from: rate, to: fs)
            if k < clips.count - 1 { voice += [Float](repeating: 0, count: fs * 4 / 100) }   // 40 ms entre trozos
        }
        let open = fs * 9 / 100, tail = fs * 18 / 100
        var out = [Float](repeating: 0, count: open + voice.count + tail)
        // Chasquido de apertura: clic + ráfaga de ruido corta
        for i in 0..<open {
            let t = Float(i) / Float(open)
            out[i] = (rng.float() * 2 - 1) * 0.35 * (1 - t) * (i < fs / 500 ? 2 : 1)
        }
        // Voz con siseo de fondo
        for i in 0..<voice.count { out[open + i] = voice[i] * 0.9 + (rng.float() * 2 - 1) * 0.012 }
        // Cola de squelch: ruido que se corta de golpe
        for i in 0..<tail {
            let t = Float(i) / Float(tail)
            out[open + voice.count + i] = (rng.float() * 2 - 1) * 0.28 * (t < 0.85 ? 1 : (1 - t) / 0.15)
        }
        // Canal de radio: paso banda 300–3400 Hz (dos etapas de cada) y saturación suave
        var f = [Biquad.make("hp", f: 300, q: 0.707, fs: 48000), Biquad.make("hp", f: 300, q: 0.707, fs: 48000),
                 Biquad.make("lp", f: 3400, q: 0.707, fs: 48000), Biquad.make("lp", f: 3400, q: 0.707, fs: 48000)]
        let drive: Float = 2.2, norm = tanhf(drive)
        for i in 0..<out.count {
            var x = out[i]
            for k in 0..<f.count { x = f[k].run(x) }
            out[i] = tanhf(x * drive) / norm * 0.85
        }
        return out
    }
}
