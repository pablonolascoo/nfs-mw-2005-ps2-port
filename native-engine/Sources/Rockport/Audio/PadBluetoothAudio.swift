// Altavoz del mando por Bluetooth: el audio va DENTRO de informes HID de salida, como hace la consola.
// macOS no publica el altavoz del DualSense / DualShock 4 por Bluetooth como dispositivo de audio; por USB sí (AudioDevices.swift).
//
// DualSense / DualSense Edge (054C:0CE6 / 0DF2) [I: investigación de la comunidad, ver créditos en docs/es/15-mandos.md §7]
//   Informe 0x36, 398 bytes: [0] 0x36 · [1] secuencia << 4 · subpaquetes «id | 0x80, longitud, datos»:
//     [2]   0x11 configuración (7): máscara de audio 0xFE (bit 0 = micrófono/dúplex, apagado), 5 × 64, contador de paquetes
//     [11]  0x10 estado (63): instantánea de estado con el micrófono silenciado
//     [76]  0x12 hápticos (64): PCM int8 a 6 kHz (aquí silencio)
//     [142] 0x13 altavoz (200): una trama Opus 48 kHz estéreo CBR 160 kbit/s = 200 bytes (0x16 = toma de auriculares)
//     [394] CRC-32 (LE) de [0xA2] + bytes 0…393
//   Cadencia: una trama cada 512/48 000 s = 10,667 ms; cada una lleva 512 muestras reescaladas a 480 (reloj del mando).
//   Antes: informe 0x31 (78 B) con altavoz activado (valid_flag0 0x80|0x20, volumen, audio_control 0x30, preamp 2).
//   Opus: el codificador del sistema (AudioToolbox, kAudioFormatOpus), que da tramas CBR de 200 bytes exactos [V en este Mac].
// DualShock 4 (054C:05C4 / 09CC) [I: habr.com/ru/post/302356]
//   Informe 0x14, 270 bytes: [0] 0x14 · [1] 0x40 · [2] 0xA0 · [3-4] contador de tramas SBC (LE, +2) · [5] 0x02 ·
//     [6] 2 tramas SBC de 112 B (32 kHz, 16 bloques, 8 subbandas, doble canal, bitpool 25) · relleno · CRC-32 al final.
//   Cadencia: 256 muestras a 32 kHz = 8 ms. Volumen por el informe 0x11 (bytes 21–25) [I].
// Si el envío falla (sin permiso, informe rechazado, mando desconectado) se marca `failed` y la radio vuelve sola a los altavoces del Mac.
import Foundation
import IOKit
import IOKit.hid
import AudioToolbox

final class PadBluetoothAudio {
    static let shared = PadBluetoothAudio()

    enum Kind: String { case dualSense = "DualSense", dualShock4 = "DualShock 4" }
    struct Pad { let device: IOHIDDevice; let kind: Kind; let name: String }

    private(set) var pads: [Pad] = []
    private(set) var failed = false
    private(set) var lastError = ""
    private var manager: IOHIDManager?
    private let queue = DispatchQueue(label: "rockport.pad-bt-audio", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var pending: [Float] = []           // 48 kHz mono, −1…1
    private let lock = NSLock()
    private var seq: UInt8 = 0, counter: UInt8 = 0, ds4Frame: UInt16 = 0
    private var idleTicks = 0, preroll = 0
    private var failures = 0
    private var opus: OpusEncoder?
    private var sbc = SBCEncoder()
    private var resampleCarry: [Float] = []
    var volume: Float = 0.8

    /// ¿Hay un mando por Bluetooth al que mandar audio?
    var available: Bool { !failed && !pads.isEmpty }
    var busy: Bool { lock.lock(); defer { lock.unlock() }; return !pending.isEmpty || timer != nil }

    // MARK: Mandos

    /// Busca mandos de Sony por Bluetooth (sin quitárselos a GameController: apertura no exclusiva).
    func start() {
        guard manager == nil else { return }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
        let match: [[String: Any]] = [0x0CE6, 0x0DF2, 0x05C4, 0x09CC].map { [kIOHIDVendorIDKey: 0x054C, kIOHIDProductIDKey: $0] }
        IOHIDManagerSetDeviceMatchingMultiple(m, match as CFArray)
        IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        refresh()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, _ in
            Unmanaged<PadBluetoothAudio>.fromOpaque(ctx!).takeUnretainedValue().refresh()
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, _ in
            Unmanaged<PadBluetoothAudio>.fromOpaque(ctx!).takeUnretainedValue().refresh()
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    func refresh() {
        guard let m = manager, let set = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice> else { pads = []; return }
        pads = set.compactMap { d in
            let transport = IOHIDDeviceGetProperty(d, kIOHIDTransportKey as CFString) as? String ?? ""
            guard transport.lowercased().contains("bluetooth") else { return nil }
            let pid = IOHIDDeviceGetProperty(d, kIOHIDProductIDKey as CFString) as? Int ?? 0
            let name = IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String ?? "mando"
            let kind: Kind = (pid == 0x05C4 || pid == 0x09CC) ? .dualShock4 : .dualSense
            return Pad(device: d, kind: kind, name: name)
        }
        if !pads.isEmpty { failed = false; failures = 0 }
    }

    // MARK: Reproducción

    /// Pone en cola audio mono a 48 kHz (−1…1). Arranca el envío si hace falta.
    func play(_ samples: [Float]) {
        guard available else { return }
        lock.lock(); pending.append(contentsOf: samples); lock.unlock()
        queue.async { self.startTimer() }
    }

    private func startTimer() {
        guard timer == nil, let pad = pads.first else { return }
        let period: Double = pad.kind == .dualSense ? 512.0 / 48000 : 256.0 / 32000
        if pad.kind == .dualSense {
            if opus == nil { opus = OpusEncoder() }
            if opus == nil { fail("el sistema no tiene codificador Opus"); return }
            send(pad, Reports.dualSenseSpeakerSetup(seq: nextSeq(), volume: volume))
            preroll = 24          // 256 ms de silencio para que el mando arranque su decodificador [I]
        } else {
            send(pad, Reports.ds4AudioSetup(volume: volume))
            preroll = 8
        }
        idleTicks = 0
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: period, leeway: .microseconds(300))
        t.setEventHandler { [weak self] in self?.tick(pad) }
        timer = t
        t.resume()
    }

    private func tick(_ pad: Pad) {
        let need = pad.kind == .dualSense ? 512 : 256 * 3 / 2    // DS4: 256 muestras a 32 kHz = 384 a 48 kHz
        var chunk = [Float](repeating: 0, count: need)
        if preroll > 0 { preroll -= 1 } else {
            lock.lock()
            let n = min(need, pending.count)
            if n > 0 { chunk.replaceSubrange(0..<n, with: pending[0..<n]); pending.removeFirst(n) }
            let empty = pending.isEmpty
            lock.unlock()
            idleTicks = empty ? idleTicks + 1 : 0
        }
        let report: [UInt8]
        if pad.kind == .dualSense {
            let pcm = Resample.linear(chunk, to: 480).map { $0 * volume }
            guard let frame = opus?.encode(pcm) else { fail("Opus no dio una trama"); return }
            report = Reports.dualSenseAudio(seq: nextSeq(), counter: counter, opus: frame)
            counter &+= 1
        } else {
            let pcm = Resample.linear(chunk, to: 256).map { $0 * volume * 32767 }
            var bytes: [UInt8] = []
            for k in 0..<2 { let part = Array(pcm[k * 128..<(k + 1) * 128]); bytes += sbc.encode([part, part]) }
            report = Reports.ds4Audio(frame: ds4Frame, sbc: bytes)
            ds4Frame &+= 2
        }
        send(pad, report)
        if idleTicks > 40 { timer?.cancel(); timer = nil }    // ~0,4 s de silencio tras la última frase
    }

    private func nextSeq() -> UInt8 { defer { seq = (seq + 1) & 0x0F }; return seq }

    private func send(_ pad: Pad, _ r: [UInt8]) {
        let res = r.withUnsafeBufferPointer { IOHIDDeviceSetReport(pad.device, kIOHIDReportTypeOutput, CFIndex(r[0]), $0.baseAddress!, r.count) }
        if res == kIOReturnSuccess { failures = 0; return }
        failures += 1
        if failures >= 5 {
            fail(String(format: "IOHIDDeviceSetReport 0x%02X (%d B) devolvió 0x%08X%@", r[0], r.count, res,
                        res == kIOReturnNotPermitted ? " (permiso de «Monitorización de entrada»)" : ""))
        }
    }

    private func fail(_ why: String) {
        failed = true; lastError = why
        timer?.cancel(); timer = nil
        lock.lock(); pending.removeAll(); lock.unlock()
        fputs("Radio por el altavoz del mando (Bluetooth) desactivada: \(why). Sigue por los altavoces del Mac.\n", stderr)
    }

    // MARK: Informes

    enum Reports {
        /// CRC-32 (polinomio de zlib) de [0xA2] + datos: la cabecera de salida HID por Bluetooth (0xA2) entra en la suma.
        static func crc32(_ data: ArraySlice<UInt8>) -> UInt32 {
            var c: UInt32 = 0xFFFF_FFFF
            func feed(_ b: UInt8) { c ^= UInt32(b); for _ in 0..<8 { c = (c >> 1) ^ (0xEDB8_8320 & (0 &- (c & 1))) } }
            feed(0xA2)
            for b in data { feed(b) }
            return ~c
        }
        static func putCRC(_ r: inout [UInt8]) {
            let c = crc32(r[0..<(r.count - 4)])
            for k in 0..<4 { r[r.count - 4 + k] = UInt8((c >> (8 * UInt32(k))) & 0xFF) }
        }

        /// Instantánea de estado (subpaquete 0x10) con el micrófono silenciado [I: comunidad].
        static let stateSnapshot: [UInt8] = {
            var s: [UInt8] = [0xFD, 0xE3, 0x00, 0x00, 0x7F, 0x64, 0x00, 0x09, 0x00, 0x10]
            s += [UInt8](repeating: 0, count: 27)            // 0x0A en el byte 37
            s += [0x0A, 0x04, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0xFF]
            s += [UInt8](repeating: 0, count: 63 - s.count)
            return s
        }()

        static func dualSenseAudio(seq: UInt8, counter: UInt8, opus: [UInt8], headset: Bool = false) -> [UInt8] {
            var r = [UInt8](repeating: 0, count: 398)
            r[0] = 0x36; r[1] = (seq & 0x0F) << 4
            r[2] = 0x11 | 0x80; r[3] = 7; r[4] = 0xFE
            for k in 5...9 { r[k] = 64 }
            r[10] = counter
            r[11] = 0x10 | 0x80; r[12] = 63; r.replaceSubrange(13..<76, with: stateSnapshot)
            r[76] = 0x12 | 0x80; r[77] = 64                       // hápticos: silencio
            r[142] = (headset ? 0x16 : 0x13) | 0x80; r[143] = 200
            for (k, b) in opus.prefix(200).enumerated() { r[144 + k] = b }
            putCRC(&r)
            return r
        }

        /// Informe 0x31: activar el altavoz [I: comunidad + estructura de hid-playstation (Linux)].
        static func dualSenseSpeakerSetup(seq: UInt8, volume: Float) -> [UInt8] {
            var r = [UInt8](repeating: 0, count: 78)
            r[0] = 0x31; r[1] = (seq & 0x0F) << 4; r[2] = 0x10
            let c = 3
            r[c + 0] = 0x80 | 0x20                // audio_control y volumen del altavoz válidos
            r[c + 1] = 0x80                       // audio_control2 válido
            r[c + 5] = UInt8(max(0, min(1, volume)) * 100)   // volumen del altavoz (0x64 = máx.)
            r[c + 7] = 0x30                       // ruta: altavoz
            r[c + 37] = 0x02                      // preamplificador
            putCRC(&r)
            return r
        }

        static func ds4Audio(frame: UInt16, sbc: [UInt8]) -> [UInt8] {
            var r = [UInt8](repeating: 0, count: 270)
            r[0] = 0x14; r[1] = 0x40; r[2] = 0xA0
            r[3] = UInt8(frame & 0xFF); r[4] = UInt8(frame >> 8); r[5] = 0x02
            for (k, b) in sbc.prefix(224).enumerated() { r[6 + k] = b }
            putCRC(&r)
            return r
        }

        /// DualShock 4, informe 0x11 solo con los campos de audio (sin tocar luz ni vibración) [I].
        static func ds4AudioSetup(volume: Float) -> [UInt8] {
            var r = [UInt8](repeating: 0, count: 78)
            r[0] = 0x11; r[1] = 0xC0; r[2] = 0x20; r[3] = 0xF0
            let v = UInt8(max(0, min(1, volume)) * 100)
            r[21] = 0x43; r[22] = 0x43; r[23] = 0x00; r[24] = v; r[25] = 0x85
            putCRC(&r)
            return r
        }
    }
}

/// Opus CBR 160 kbit/s, 48 kHz estéreo, tramas de 480 muestras = 200 bytes (codificador de AudioToolbox).
final class OpusEncoder {
    private var conv: AudioConverterRef?
    private var input: [Int16] = []
    private var inputPos = 0

    init?() {
        var inF = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                                              mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                              mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var outF = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
                                               mFramesPerPacket: 480, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        guard AudioConverterNew(&inF, &outF, &conv) == noErr, let conv else { return nil }
        var br: UInt32 = 160_000, mode: UInt32 = kAudioCodecBitRateControlMode_Constant
        AudioConverterSetProperty(conv, kAudioConverterEncodeBitRate, 4, &br)
        AudioConverterSetProperty(conv, kAudioCodecPropertyBitRateControlMode, 4, &mode)
        // Cebar el codificador con silencio: así siempre hay una trama válida que repetir mientras arranca
        for _ in 0..<6 where last == nil { _ = encode([Float](repeating: 0, count: 480)) }
        guard last != nil else { return nil }
    }
    deinit { if let conv { AudioConverterDispose(conv) } }

    /// 480 muestras mono (−1…1) → una trama Opus (el mismo canal en izquierda y derecha: izquierda = altavoz).
    /// El codificador tiene retardo propio: si aún no ha sacado trama, se devuelve una de silencio para no cortar la cadencia.
    func encode(_ mono: [Float]) -> [UInt8]? {
        guard let conv else { return nil }
        input.removeFirst(inputPos); inputPos = 0
        for v in mono { let s = Int16(max(-32767, min(32767, v * 32767))); input.append(s); input.append(s) }
        var out = [UInt8](repeating: 0, count: 1500)
        var packets: UInt32 = 1
        var desc = AudioStreamPacketDescription()
        let st = out.withUnsafeMutableBytes { ob -> OSStatus in
            var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: 1500, mData: ob.baseAddress))
            return AudioConverterFillComplexBuffer(conv, { _, ioN, ioData, _, user in
                let me = Unmanaged<OpusEncoder>.fromOpaque(user!).takeUnretainedValue()
                let avail = (me.input.count - me.inputPos) / 2
                let n = min(Int(ioN.pointee), avail)
                ioN.pointee = UInt32(n)
                if n == 0 { ioData.pointee.mBuffers.mDataByteSize = 0; return 1 }   // «sin más datos por ahora»
                me.input.withUnsafeMutableBufferPointer { b in ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(b.baseAddress! + me.inputPos) }
                ioData.pointee.mBuffers.mDataByteSize = UInt32(n * 4); ioData.pointee.mBuffers.mNumberChannels = 2
                me.inputPos += n * 2
                return noErr
            }, Unmanaged.passUnretained(self).toOpaque(), &packets, &abl, &desc)
        }
        guard st == noErr || st == 1 else { return nil }
        if packets == 1 && desc.mDataByteSize > 0 { let f = Array(out.prefix(Int(desc.mDataByteSize))); last = f; return f }
        return last
    }
    private var last: [UInt8]?
}

enum Resample {
    /// Remuestreo lineal de un bloque a `n` muestras (voz de radio: suficiente).
    static func linear(_ x: [Float], to n: Int) -> [Float] {
        guard x.count > 1, n > 0 else { return [Float](repeating: x.first ?? 0, count: n) }
        if x.count == n { return x }
        let step = Double(x.count - 1) / Double(max(1, n - 1))
        return (0..<n).map { i in
            let p = Double(i) * step, k = Int(p), f = Float(p - Double(k))
            return k + 1 < x.count ? x[k] * (1 - f) + x[k + 1] * f : x[x.count - 1]
        }
    }
    /// Cambio de frecuencia de una señal entera (p. ej. 22 050 → 48 000 Hz).
    static func rate(_ x: [Float], from a: Int, to b: Int) -> [Float] {
        guard a != b, !x.isEmpty else { return x }
        return linear(x, to: max(1, Int((Double(x.count) * Double(b) / Double(a)).rounded())))
    }
}
