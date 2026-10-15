// Pruebas sin ventana del audio de la radio y del mando (no hace falta mando):
//   Rockport --audio-devices                 salidas de CoreAudio (¿altavoz del mando por USB?) y mandos de Sony por Bluetooth
//   Rockport --radio-test [--data <carpeta>]  decodifica clips con MicroTalk.swift, compara con vgmstream si está instalado,
//                                            y escribe frases de persecución ya filtradas en .build/radio-test/*.wav
//   Rockport --pad-audio-test                Opus (ida y vuelta con AudioToolbox), SBC (decodificado con FFmpeg si está),
//                                            informes HID 0x36 / 0x31 / 0x14 y su CRC-32; ficheros en .build/pad-audio-test/
//   Rockport --lightbar-test                 colores de la barra de luz por modo y estado (tabla en texto)
import Foundation
import AudioToolbox
import simd

enum AudioTests {
    /// true si el argumento era una de estas pruebas (ya se ha ejecutado y hay que salir).
    static func handle(_ a: [String]) -> Bool {
        if a.contains("--audio-devices") { devices(); return true }
        if a.contains("--radio-test") { radio(a); return true }
        if a.contains("--pad-audio-test") { padAudio(); return true }
        if a.contains("--lightbar-test") { lightbar(); return true }
        return false
    }

    static func outDir(_ name: String) -> URL {
        let u = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/\(name)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func writeWav(_ x: [Float], rate: Int, to url: URL) {
        var d = Data()
        func u32(_ v: UInt32) { var l = v.littleEndian; d.append(Data(bytes: &l, count: 4)) }
        func u16(_ v: UInt16) { var l = v.littleEndian; d.append(Data(bytes: &l, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + x.count * 2)); d.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(UInt32(x.count * 2))
        for v in x { u16(UInt16(bitPattern: Int16(max(-32768, min(32767, (v * 32768).rounded()))))) }
        try? d.write(to: url)
    }

    // MARK: Dispositivos

    static func devices() {
        print("Salidas de audio (CoreAudio):")
        for d in AudioDevices.outputs() { print("  \(d.isController ? "★" : " ") \(d)") }
        if let p = AudioDevices.controllerSpeaker() { print("Altavoz del mando por USB: \(p.name)") }
        else { print("Ningún mando por USB como salida de audio (DualSense / DualShock 4 enchufado por cable aparecería aquí).") }
        let bt = PadBluetoothAudio.shared
        bt.start()
        print(bt.pads.isEmpty ? "Ningún DualSense / DualShock 4 por Bluetooth visible por IOHID."
                              : "Por Bluetooth (audio por informes HID): " + bt.pads.map { "\($0.name) (\($0.kind.rawValue))" }.joined(separator: ", "))
    }

    // MARK: Radio

    static func radio(_ a: [String]) {
        let dataArg = a.firstIndex(of: "--data").flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
        let (root, tried) = DataLocator.locate(arg: dataArg, disc: nil)
        guard let root, let lib = RadioLibrary(root: root) else {
            fputs("No hay radio/ en los datos. Buscado en:\n\(tried.joined(separator: "\n"))\nConvierte con: cd tools && bun src/cli/radio.ts <iso> <ID>\n", stderr); exit(1)
        }
        let out = outDir("radio-test")
        print("Radio: \(lib.index.clips.count) clips (\(lib.lang)), \(lib.index.banks.count) bancos, \(lib.index.events.count) eventos, \(lib.voices) voces · \(root.path)")
        // 1. Decodificación: longitudes y picos; comparación con vgmstream si existe
        let vgm = ["/opt/homebrew/bin/vgmstream-cli", "/usr/local/bin/vgmstream-cli"].first { FileManager.default.isExecutableFile(atPath: $0) }
        var bad = 0, maxDiff = 0, diffs = 0, total = 0
        let t0 = CACurrentMediaTimeShim.now()
        var rng = SplitMix(seed: 7)
        let picks = [0, 100, 2399] + (0..<37).map { _ in Int(rng.next() % UInt64(lib.index.clips.count)) }
        for k in picks {
            let s = lib.samples(k), want = lib.index.clips[k][2]
            if s.count != want { bad += 1; print("  clip \(k): \(s.count) muestras, el índice dice \(want)") }
            guard let vgm else { continue }
            let c = lib.index.clips[k]
            let asf = out.appendingPathComponent("c.asf"), wav = out.appendingPathComponent("c.wav")
            let big = try! Data(contentsOf: root.appendingPathComponent("radio/COPSPEECH.BIG"), options: .alwaysMapped)
            try? big.subdata(in: c[0]..<(c[0] + c[1])).write(to: asf)
            let p = Process(); p.executableURL = URL(fileURLWithPath: vgm); p.arguments = ["-o", wav.path, asf.path]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
            guard let w = try? Data(contentsOf: wav), w.count > 44 else { continue }
            let ch = Int(w[22])
            let ref: [Int16] = w.subdata(in: 44..<w.count).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            for i in 0..<min(s.count, ref.count / ch) {
                var r = 0.0; for c in 0..<ch { r += Double(ref[i * ch + c]) }; r /= Double(ch)
                let d = Int(abs(Double(s[i]) * 32768 - r).rounded()); total += 1
                if d > 0 { diffs += 1; maxDiff = max(maxDiff, d) }
            }
        }
        try? FileManager.default.removeItem(at: out.appendingPathComponent("c.asf")); try? FileManager.default.removeItem(at: out.appendingPathComponent("c.wav"))
        print(String(format: "  %d clips decodificados en %.2f s · longitudes erróneas: %d", picks.count, CACurrentMediaTimeShim.now() - t0, bad))
        if vgm != nil { print("  contra vgmstream: \(total) muestras, distintas \(diffs) (\(String(format: "%.3f", Double(diffs) * 100 / Double(max(1, total)))) %), diferencia máx. \(maxDiff) (estéreo: media de canales)") }
        else { print("  (sin vgmstream-cli: no se compara)") }
        // 2. Frases de persecución con el filtro de radio
        let radio = PoliceRadio.shared
        radio.silent = true
        radio.attach(root: root)
        let lines: [(String, [Int: Int])] = [("InitPursuit", [2: 0]), ("CallForBU", [2: 0, 3: 3]), ("HeatJump", [2: 1]), ("CallForRB", [2: 0, 3: 1]),
                                             ("RBApproach", [2: 1]), ("LostVisual", [2: 0]), ("RegainVisual", [2: 1]), ("LostSuspect", [2: 0]),
                                             ("Arrest", [2: 1]), ("DispArrestReply", [:]), ("Disp911Report", [3: 0]), ("PursuitUpdateRep", [:])]
        var missing: [String] = []
        for (ev, params) in lines {
            guard let clips = lib.line(ev, voice: 2, params: params, rng: &rng) else { missing.append(ev); continue }
            let pcm = RadioDSP.transmission(clips.map { lib.samples($0) }, rate: lib.index.sampleRate, rng: &rng)
            let peak = pcm.map(abs).max() ?? 0
            writeWav(pcm, rate: 48000, to: out.appendingPathComponent("\(ev).wav"))
            print(String(format: "  %-18@ %d trozo(s) %@ · %.2f s · pico %.2f", ev as NSString, clips.count, clips.map(String.init).joined(separator: "+"), Double(pcm.count) / 48000, peak))
        }
        if !missing.isEmpty { print("  sin línea: \(missing.joined(separator: ", "))") }
        print("WAV → \(out.path)")
        exit(bad == 0 && missing.isEmpty && maxDiff <= 1 ? 0 : 1)
    }

    // MARK: Mando por Bluetooth (sin mando)

    static func padAudio() {
        let out = outDir("pad-audio-test")
        var ok = true
        // 1. CRC-32 con la cabecera 0xA2 (valores de zlib.crc32(b"\xa2" + …))
        let c1 = PadBluetoothAudio.Reports.crc32(ArraySlice(Array("123456789".utf8)))
        let c2 = PadBluetoothAudio.Reports.crc32(ArraySlice((0..<74).map { UInt8($0) }))
        let crcOK = c1 == 0x63DA_9F12 && c2 == 0x3777_8AD7
        ok = ok && crcOK
        print(String(format: "CRC-32 (semilla 0xA2): %08X %08X → %@", c1, c2, crcOK ? "bien" : "MAL"))
        // 2. Opus: 2 s de voz sintética → tramas de 200 B → decodificar con AudioToolbox y medir
        guard let enc = OpusEncoder() else { print("Opus: el sistema no tiene codificador"); exit(1) }
        var tone = [Float](repeating: 0, count: 96000)
        for i in 0..<tone.count { let t = Double(i) / 48000; tone[i] = Float(0.3 * sin(2 * .pi * 440 * t) + 0.2 * sin(2 * .pi * (300 + 900 * t) * t)) }
        var frames: [[UInt8]] = []
        for k in stride(from: 0, to: tone.count - 512, by: 512) { if let f = enc.encode(Resample.linear(Array(tone[k..<(k + 512)]), to: 480)) { frames.append(f) } }
        let sizes = Set(frames.map(\.count))
        let opusOK = sizes == [200]
        ok = ok && opusOK
        let dec = opusDecode(frames)
        let rms = sqrt(dec.reduce(0) { $0 + $1 * $1 } / Float(max(1, dec.count)))
        print("Opus: \(frames.count) tramas, tamaños \(sizes.sorted()) B (deben ser 200) · decodificado \(dec.count) muestras, RMS \(String(format: "%.3f", rms)) (entrada ≈ 0,25)")
        writeWav(dec, rate: 48000, to: out.appendingPathComponent("opus-roundtrip.wav"))
        // 3. Informe 0x36 completo
        let r36 = PadBluetoothAudio.Reports.dualSenseAudio(seq: 3, counter: 7, opus: frames.first ?? [])
        let crc36 = PadBluetoothAudio.Reports.crc32(r36[0..<394])
        let r36ok = r36.count == 398 && r36[0] == 0x36 && r36[1] == 0x30 && r36[2] == 0x91 && r36[11] == 0x90 && r36[76] == 0x92 && r36[142] == 0x93 && r36[143] == 200
            && r36[13 + 37] == 0x0A && UInt32(r36[394]) | UInt32(r36[395]) << 8 | UInt32(r36[396]) << 16 | UInt32(r36[397]) << 24 == crc36
        ok = ok && r36ok
        print("Informe 0x36: \(r36.count) B, subpaquetes 0x91/0x90/0x92/0x93 en 2/11/76/142, CRC al final → \(r36ok ? "bien" : "MAL")")
        try? Data(r36).write(to: out.appendingPathComponent("report-0x36.bin"))
        let r31 = PadBluetoothAudio.Reports.dualSenseSpeakerSetup(seq: 0, volume: 0.8)
        print("Informe 0x31: \(r31.count) B · flags \(String(format: "%02X %02X", r31[3], r31[4])) · volumen \(r31[8]) · ruta \(String(format: "0x%02X", r31[10]))")
        // 4. SBC del DualShock 4: codificar, empaquetar en 0x14 y decodificar con FFmpeg si está
        var sbc = SBCEncoder()
        var stream = Data(), reports = 0
        let t32 = Resample.rate(tone, from: 48000, to: 32000).map { $0 * 32767 }
        var frame: UInt16 = 0
        for k in stride(from: 0, to: t32.count - 256, by: 256) {
            var two: [UInt8] = []
            for j in 0..<2 { let part = Array(t32[(k + j * 128)..<(k + j * 128 + 128)]); two += sbc.encode([part, part]) }
            let r = PadBluetoothAudio.Reports.ds4Audio(frame: frame, sbc: two); frame &+= 2; reports += 1
            if r.count != 270 || r[6] != 0x9C || r[7] != 0x75 || r[8] != 0x19 || r[6 + 112] != 0x9C { ok = false }
            stream.append(contentsOf: two)
        }
        let sbcURL = out.appendingPathComponent("ds4.sbc"); try? stream.write(to: sbcURL)
        print("SBC: \(reports) informes 0x14 de 270 B, tramas de \(sbc.frameBytes) B con cabecera 9C 75 19 (32 kHz, 16 bloques, doble canal, bitpool 25)")
        if let ff = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            let raw = out.appendingPathComponent("ds4-dec.raw")
            let p = Process(); p.executableURL = URL(fileURLWithPath: ff)
            p.arguments = ["-v", "error", "-y", "-f", "sbc", "-i", sbcURL.path, "-f", "s16le", "-ac", "1", raw.path]
            try? p.run(); p.waitUntilExit()
            if let d = try? Data(contentsOf: raw) {
                let dec: [Float] = d.withUnsafeBytes { $0.bindMemory(to: Int16.self).map { Float($0) } }
                // Mejor SNR con retardo 0…200 (el banco de filtros retrasa ~73 muestras)
                var best = (-99.0, 0)
                for lag in 0..<200 {
                    var e = 0.0, s = 0.0
                    for i in stride(from: 2000, to: min(t32.count, dec.count - lag) - 1000, by: 3) {
                        let a = Double(t32[i]), b = Double(dec[i + lag]); s += a * a; e += (a - b) * (a - b)
                    }
                    let snr = 10 * log10(s / max(e, 1e-9)); if snr > best.0 { best = (snr, lag) }
                }
                let sbcOK = best.0 > 30
                ok = ok && sbcOK
                print(String(format: "SBC decodificado por FFmpeg: SNR %.1f dB (retardo %d muestras) → %@", best.0, best.1, sbcOK ? "bien" : "MAL"))
            }
        } else { print("(sin ffmpeg: el SBC no se decodifica)") }
        print("Ficheros → \(out.path)")
        print("Sin mando no se puede probar: que macOS acepte IOHIDDeviceSetReport de 398/270 B por Bluetooth, la cadencia real y que suene.")
        exit(ok ? 0 : 1)
    }

    /// Opus → PCM mono con AudioToolbox (solo para la prueba).
    static func opusDecode(_ frames: [[UInt8]]) -> [Float] {
        var inF = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
                                              mFramesPerPacket: 480, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        var outF = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var conv: AudioConverterRef?
        guard AudioConverterNew(&inF, &outF, &conv) == noErr, let conv else { return [] }
        defer { AudioConverterDispose(conv) }
        final class Feed { var frames: [[UInt8]]; var i = 0; var desc = AudioStreamPacketDescription(); var buf: [UInt8] = []; init(_ f: [[UInt8]]) { frames = f } }
        let feed = Feed(frames)
        var out: [Float] = []
        var tmp = [Float](repeating: 0, count: 960 * 2)
        while true {
            var n: UInt32 = 960
            let st = tmp.withUnsafeMutableBytes { tb -> OSStatus in
                var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(tb.count), mData: tb.baseAddress))
                return AudioConverterFillComplexBuffer(conv, { _, ioN, ioData, outDesc, user in
                    let f = Unmanaged<Feed>.fromOpaque(user!).takeUnretainedValue()
                    guard f.i < f.frames.count else { ioN.pointee = 0; return 1 }
                    f.buf = f.frames[f.i]; f.i += 1
                    ioN.pointee = 1
                    f.buf.withUnsafeMutableBytes { ioData.pointee.mBuffers.mData = $0.baseAddress }
                    ioData.pointee.mBuffers.mDataByteSize = UInt32(f.buf.count); ioData.pointee.mBuffers.mNumberChannels = 2
                    f.desc = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(f.buf.count))
                    if let outDesc { withUnsafeMutablePointer(to: &f.desc) { outDesc.pointee = $0 } }
                    return noErr
                }, Unmanaged.passUnretained(feed).toOpaque(), &n, &abl, nil)
            }
            for i in 0..<Int(n) { out.append(tmp[2 * i]) }
            if n == 0 || (st != noErr && st != 1) || feed.i >= frames.count && n < 960 { break }
        }
        return out
    }

    // MARK: Barra de luz

    static func lightbar() {
        let lb = LightBar.shared
        let paint = SIMD3<Float>(0.68, 0.72, 0.76)
        func hex(_ c: SIMD3<Float>) -> String { String(format: "%02X%02X%02X", Int(c.x * 255), Int(c.y * 255), Int(c.z * 255)) }
        print("Modo actual: \(lb.settings.mode.rawValue) (archivo: \(LightBar.settingsURL.path))")
        for (state, heat) in [(PursuitLight.none, Float(1)), (.chase, 1), (.chase, 5), (.cooldown, 3), (.busted, 3), (.evaded, 3)] {
            lb.note(state, heat: heat)
            let samples = stride(from: 0.0, to: 1.6, by: 0.1).map { hex(lb.color(time: 100 + $0, paint: paint)) }
            print(String(format: "  %-9@ calor %.0f: %@", "\(state)" as NSString, heat, samples.joined(separator: " ")))
        }
        lb.note(.none, heat: 1)
    }
}
