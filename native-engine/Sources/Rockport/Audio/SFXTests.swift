// Pruebas sin ventana del sonido del juego:
//   Rockport --sound-dump [--data <carpeta>]           bancos, motores .GIN y coches de sound.json; decodifica todo y compara
//                                                      con vgmstream-cli si está instalado (solo para comprobar)
//   Rockport --sound-test [COCHE] [--data <carpeta>]   recorrido con guion (ralentí, aceleración con cambios, soltar, nitro,
//                                                      frenada y freno de mano) con la física del juego en un plano, render
//                                                      sin tiempo real (AVAudioEngine manual) → .build/sound-test/<COCHE>.wav
import Foundation
import AVFoundation
import simd

enum SFXTests {
    static func handle(_ a: [String]) -> Bool {
        if a.contains("--sound-dump") { dump(a); return true }
        if let i = a.firstIndex(of: "--sound-live") {
            live(a, seconds: i + 1 < a.count ? Double(a[i + 1]) ?? 3 : 3)
            return true
        }
        if let i = a.firstIndex(of: "--sound-test") {
            test(a, car: i + 1 < a.count && !a[i + 1].hasPrefix("-") ? a[i + 1] : Config.playerCar)
            return true
        }
        return false
    }

    private static func root(_ a: [String]) -> URL {
        let dataArg = a.firstIndex(of: "--data").flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
        let (root, tried) = DataLocator.locate(arg: dataArg, disc: nil)
        guard let root else { fputs("No encuentro datos. Buscado en:\n\(tried.joined(separator: "\n"))\n", stderr); exit(1) }
        return root
    }

    static func writeWav(_ l: [Float], _ r: [Float], rate: Int, to url: URL) {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + l.count * 4)); d.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(2); u32(UInt32(rate)); u32(UInt32(rate * 4)); u16(4); u16(16)
        d.append("data".data(using: .ascii)!); u32(UInt32(l.count * 4))
        d.reserveCapacity(d.count + l.count * 4)
        for i in 0..<l.count {
            u16(UInt16(bitPattern: Int16(max(-32768, min(32767, (l[i] * 32767).rounded())))))
            u16(UInt16(bitPattern: Int16(max(-32768, min(32767, (r[i] * 32767).rounded())))))
        }
        try? d.write(to: url)
    }

    // MARK: --sound-dump

    static func dump(_ a: [String]) {
        let root = root(a)
        guard let lib = SFXLibrary(root: root) else { fputs("No hay sound/ en \(root.path). Convierte con: cd tools && bun src/cli/sound.ts <iso> <ID>\n", stderr); exit(1) }
        print("Sonido · \(root.path)/sound")
        let t0 = CACurrentMediaTimeShim.now()
        var sounds = 0, samples = 0, seconds = 0.0
        for b in lib.bankNames {
            let n = lib.soundCount(b)
            var parts: [String] = []
            for k in 0..<n {
                guard let s = lib.sample(b, k) else { parts.append("#\(k) ¡error!"); continue }
                sounds += 1; samples += s.data.count; seconds += s.duration
                parts.append(String(format: "#%d %.1fk %.2fs%@", k, Double(s.rate) / 1000, s.duration, s.loop != nil ? " bucle" : ""))
            }
            print("  \(b): \(parts.joined(separator: " · "))")
        }
        var ginBad = 0
        for (path, _) in lib.gins.sorted(by: { $0.key < $1.key }) {
            guard let g = lib.gin(path) else { print("  \(path): ¡no se lee!"); ginBad += 1; continue }
            let c = g.cycleRPM
            samples += g.sampleCount; seconds += Double(g.sampleCount) / Double(g.sampleRate)
            print(String(format: "  %@: %.0f–%.0f RPM · ciclos %d (%.0f → %.0f RPM) · %.2f s a %d Hz", path, g.minFrequency, g.maxFrequency, g.cycleCount, c.first, c.last, Double(g.sampleCount) / Double(g.sampleRate), g.sampleRate))
        }
        print(String(format: "Decodificado: %d sonidos + %d motores, %.1f M muestras (%.0f min) en %.2f s", sounds, lib.gins.count - ginBad, Double(samples) / 1e6, seconds / 60, CACurrentMediaTimeShim.now() - t0))
        for (name, c) in lib.cars.sorted(by: { $0.key < $1.key }) where (c["class"] as? String) == "CAR" {
            let e = (c["engine"] as? String) ?? "-"
            let accel = (lib.engines[e]?["Filename_GinsuAccel"] as? String)?.split(separator: "/").last ?? "-"
            print("  coche \(name): motor \(e) (\(accel)) · turbo \(c["turbo"] as? String ?? "no") · cambio \(c["shift"] as? String ?? "-")")
        }
        // Comparación con vgmstream (solo si está instalado en este Mac)
        let vgm = ["/opt/homebrew/bin/vgmstream-cli", "/usr/local/bin/vgmstream-cli"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let vgm else { print("vgmstream-cli no está: sin comparación"); return }
        let out = AudioTests.outDir("sound-test")
        var exact = 0, total = 0, maxDiff = 0
        let picks = ["IG_GLOBAL/SIREN_MB.ABK", "ENGINE/CAR_00_ENG_MB_EE.ABK", "SKIDS/SKID_BIG_MB.ABK", "TURBO/TURBO_MED_0_MB.ABK", "NOS/NITROUS_01_MB.ABK", "IG_GLOBAL/STICH_COLLISION_MB.ABK"]
        for b in picks where lib.soundCount(b) > 0 {
            for k in 0..<min(lib.soundCount(b), 12) {
                let wav = out.appendingPathComponent("v.wav")
                let p = Process(); p.executableURL = URL(fileURLWithPath: vgm)
                p.arguments = ["-s", String(k + 1), "-i", "-o", wav.path, root.appendingPathComponent("sound/\(b)").path]
                p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                try? p.run(); p.waitUntilExit()
                guard let w = try? Data(contentsOf: wav), w.count > 44, let s = lib.sample(b, k) else { continue }
                let n = (w.count - 44) / 2
                total += 1
                if n != s.data.count { print("  \(b) #\(k): \(n) muestras en vgmstream, \(s.data.count) aquí"); continue }
                var md = 0
                w.withUnsafeBytes { raw in
                    for i in 0..<n {
                        let ref = Int(raw.loadUnaligned(fromByteOffset: 44 + 2 * i, as: Int16.self))
                        md = max(md, abs(ref - Int((s.data[i] * 32768).rounded())))
                    }
                }
                if md == 0 { exact += 1 }
                maxDiff = max(maxDiff, md)
            }
        }
        print("Comparación con vgmstream: \(exact)/\(total) sonidos idénticos (diferencia máxima \(maxDiff); solo cambian las muestras saturadas: la SPU guarda la historia saturada)")
    }

    // MARK: --sound-live (salida real del Mac, para comprobar el camino en tiempo real; con --volume 0 no se oye)

    static func live(_ a: [String], seconds: Double) {
        let root = root(a)
        let car = Config.playerCar
        guard let data = try? GameData(root: root), let pf = PhysicsFile.load(data), let specs = pf.specs(model: car) else { exit(1) }
        let world = SFXWorld.shared
        guard world.prepare(root: root, outRate: 48000), let lib = world.lib, let mixer = world.mixer,
              let cs = SFXCarSound(lib: lib, mixer: mixer, car: car, isLocal: true, seed: 3) else { exit(1) }
        world.startOutput()
        let v = PVehicle(specs: specs, dimension: V3(0.92, 0.65, 2.3), ground: FlatGround(z: 0))
        v.place(world: float3(0, 0, 0), yaw: 0, probe: 5)
        let t0 = CACurrentMediaTimeShim.now()
        var steps = 0, maxPeak: Float = 0
        while CACurrentMediaTimeShim.now() - t0 < seconds {
            var d = DriverInput(); d.gas = 1
            v.step(d)
            cs.update(SFXCarState(vehicle: v), dt: 1.0 / 60, space: .local)
            maxPeak = max(maxPeak, mixer.peak)
            steps += 1
            Thread.sleep(forTimeInterval: 1.0 / 60)
        }
        print(String(format: "Sonido en tiempo real: %@ · %d pasos · %.0f rpm al final · pico de la mezcla antes del volumen %.2f (volumen %.0f %%)",
                     world.isRunning ? "AVAudioEngine sonando" : "AVAudioEngine NO arrancó", steps, v.engine.rpm, maxPeak, mixer.master * 100))
    }

    // MARK: --sound-test

    static func test(_ a: [String], car: String) {
        let root = root(a)
        guard let data = try? GameData(root: root), let pf = PhysicsFile.load(data), let specs = pf.specs(model: car) else {
            fputs("Sin physics.json o sin el coche \(car)\n", stderr); exit(1)
        }
        let world = SFXWorld.shared
        guard world.prepare(root: root, outRate: 48000), let lib = world.lib, let mixer = world.mixer else { exit(1) }
        mixer.master = 1; mixer.muted = false
        guard let cs = SFXCarSound(lib: lib, mixer: mixer, car: car, isLocal: true, seed: 1) else {
            fputs("sound.json no tiene el coche \(car)\n", stderr); exit(1)
        }
        let carInfo = lib.carSounds(car) ?? [:]
        print("Prueba de sonido · \(car) · motor \(carInfo["engine"] as? String ?? "-") (\(cs.engine?.spec.accel ?? "-") + \(cs.engine?.spec.decel ?? "-")) · turbo \(carInfo["turbo"] as? String ?? "no") · cambio \(carInfo["shift"] as? String ?? "-")")

        // Física del juego en un plano (como --physics-test, sin malla ni GPU)
        let v = PVehicle(specs: specs, dimension: V3(0.92, 0.65, 2.3), ground: FlatGround(z: 0))
        v.place(world: float3(0, 0, 0), yaw: 0, probe: 5)

        // Render manual de AVAudioEngine con el nodo del mezclador
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let eng = AVAudioEngine()
        let node = mixer.makeNode()
        eng.attach(node); eng.connect(node, to: eng.mainMixerNode, format: fmt)
        do { try eng.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 4096); try eng.start() }
        catch { fputs("AVAudioEngine (render manual): \(error)\n", stderr); exit(1) }
        let buf = AVAudioPCMBuffer(pcmFormat: eng.manualRenderingFormat, frameCapacity: 4096)!

        // Guion: tramos (segundos, entrada)
        struct Seg { let t: Float; let name: String; let input: (Float) -> DriverInput }
        func di(gas: Float = 0, brake: Float = 0, hb: Float = 0, steer: Float = 0, nos: Bool = false) -> DriverInput {
            var d = DriverInput(); d.gas = gas; d.brake = brake; d.handBrake = hb; d.steerRight = max(0, steer); d.steerLeft = max(0, -steer); d.nos = nos; return d
        }
        let script: [Seg] = [
            Seg(t: 2.0, name: "ralentí", input: { _ in di() }),
            Seg(t: 11.0, name: "a fondo (cambios automáticos)", input: { _ in di(gas: 1) }),
            Seg(t: 2.5, name: "suelta (retención)", input: { _ in di() }),
            Seg(t: 3.0, name: "a fondo con nitro", input: { _ in di(gas: 1, nos: true) }),
            Seg(t: 1.0, name: "suelta", input: { _ in di() }),
            Seg(t: 2.0, name: "frenada fuerte", input: { _ in di(brake: 1) }),
            Seg(t: 2.5, name: "gas y freno de mano girando (derrape)", input: { t in di(gas: t < 0.6 ? 0.5 : 1, hb: t < 0.8 ? 1 : 0, steer: 1) }),
            Seg(t: 2.0, name: "ralentí", input: { _ in di() }),
        ]
        var L: [Float] = [], R: [Float] = []
        let dt: Float = 1.0 / 60
        var renderTime = 0.0, logicTime = 0.0
        var clock: Float = 0
        var maxPeak: Float = 0
        var traceLines: [String] = []
        var sinceTrace: Float = 1
        for seg in script {
            var t: Float = 0
            var rms: Double = 0, n = 0, peak: Float = 0
            var rpmMin = Float.greatestFiniteMagnitude, rpmMax: Float = 0, gears = Set<Int>()
            while t < seg.t {
                let tl = CACurrentMediaTimeShim.now()
                v.step(seg.input(t))
                var st = SFXCarState(vehicle: v)
                st.position = float3(0, 0, 0)
                cs.update(st, dt: dt, space: .local)
                logicTime += CACurrentMediaTimeShim.now() - tl
                // 800 cuadros por paso de 1/60 s
                let tr = CACurrentMediaTimeShim.now()
                let st2 = try? eng.renderOffline(800, to: buf)
                renderTime += CACurrentMediaTimeShim.now() - tr
                guard st2 == .success, let ch = buf.floatChannelData else { fputs("render manual falló\n", stderr); exit(1) }
                for i in 0..<Int(buf.frameLength) {
                    let l = ch[0][i], r = ch[1][i]
                    L.append(l); R.append(r)
                    rms += Double(l * l + r * r) / 2; n += 1; peak = max(peak, abs(l), abs(r))
                }
                rpmMin = min(rpmMin, v.engine.rpm); rpmMax = max(rpmMax, v.engine.rpm); gears.insert(v.engine.gear - 1)
                sinceTrace += dt
                if sinceTrace >= 0.5 {
                    sinceTrace = 0
                    let o = cs.lastOut
                    traceLines.append(String(format: "  t %5.1f  %6.0f rpm  marcha %d  %5.1f km/h  audio %5.0f  GIN %5.0f  acel %.2f  desac %.2f  par %3.0f%@",
                                             clock + t, v.engine.rpm, v.engine.gear - 1, v.speed * 3.6, o.audioRPM, o.ginsuFreq, o.accelGain, o.decelGain, o.torque,
                                             cs.engine?.isShifting == true ? "  (cambio)" : ""))
                }
                t += dt
            }
            clock += seg.t
            maxPeak = max(maxPeak, peak)
            let db = 10 * log10(max(1e-12, rms / Double(max(1, n))))
            print(String(format: "  %-40@ %4.1f s · %5.0f–%5.0f rpm · marchas %@ · nivel %5.1f dBFS · pico %.2f · %3.0f km/h al final",
                         seg.name as NSString, seg.t, rpmMin, rpmMax, gears.sorted().map(String.init).joined(separator: ","), db, peak, v.speed * 3.6))
        }
        if a.contains("--sound-trace") { print(traceLines.joined(separator: "\n")) }
        print("Sonidos lanzados: " + cs.events.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: " · "))
        // Mundo: un coche de policía pasa a 35 m/s a 8 m con la sirena y su motor (Doppler y paneo), golpes de cada
        // intensidad (stitches del juego) y un claxon del tráfico
        let worldStart = L.count
        world.setListeners([SFXListener(position: .zero, forward: float3(1, 0, 0), velocity: .zero)])
        var rngW = SplitMix(seed: 99)
        var passVoices: [SFXVoice] = []
        if let sb = lib.miscBank("SIREN_MB"), let smp = lib.sample(sb, 2) {
            let v = SFXSampleVoice(smp, loop: true, tag: "test-siren"); mixer.add(v); passVoices.append(v)
        }
        if let cs = lib.carSounds("copmidsize"), let en = cs["engine"] as? String, let acc = lib.engines[en]?["Filename_GinsuAccel"] as? String, let g = lib.gin(acc) {
            let v = SFXGinsuVoice(g, tag: "test-cop"); mixer.add(v); passVoices.append(v)
        }
        let tb = lib.miscBank("TRAFFIC_MB")
        var tw: Float = 0
        var fired = Set<Int>()
        while tw < 9 {
            let x = -160 + 35 * tw
            let sp = world.space(at: float3(x, 8, 1), velocity: float3(35, 0, 0), ref: 18, maxDistance: 500)
            mixer.withLock {
                for v in passVoices {
                    let isSiren = v is SFXSampleVoice
                    let g = isSiren ? SFXMix.siren : SFXMix.opponentEngine * 0.6
                    v.params.gainL = sp.gainL * g; v.params.gainR = sp.gainR * g; v.params.pitch = sp.doppler
                    v.params.lowpass = isSiren ? max(2500, sp.lowpass) : sp.lowpass
                    v.params.ginsuFreq = 5200
                }
            }
            for (k, lvl) in ["VLIT", "LIT", "MED", "HRD"].enumerated() where tw >= 5 + Float(k) * 0.6 && !fired.contains(k) {
                fired.insert(k)
                world.playStitch(prefix: "CRSH_CAR_2_WALL_FRNT_\(lvl)", space: world.space(at: float3(3, 0, 0), velocity: .zero, ref: 10), rng: &rngW)
            }
            if tw >= 8, !fired.contains(9), let tb, let smp = lib.sample(tb, 2) {
                fired.insert(9)
                let sp2 = world.space(at: float3(-6, 4, 1), velocity: .zero, ref: 12)
                let v = SFXSampleVoice(smp, loop: false, tag: "test-horn"); v.params.gainL = sp2.gainL * SFXMix.horn; v.params.gainR = sp2.gainR * SFXMix.horn
                mixer.add(v)
            }
            guard (try? eng.renderOffline(800, to: buf)) == .success, let ch = buf.floatChannelData else { break }
            for i in 0..<Int(buf.frameLength) { L.append(ch[0][i]); R.append(ch[1][i]) }
            tw += dt
        }
        for v in passVoices { mixer.remove(v) }
        var lE: Float = 0, rE: Float = 0, lE2: Float = 0, rE2: Float = 0
        let half = worldStart + 48000 * 3
        for i in worldStart..<min(half, L.count) { lE += L[i] * L[i]; rE += R[i] * R[i] }
        for i in half..<min(worldStart + 48000 * 6, L.count) { lE2 += L[i] * L[i]; rE2 += R[i] * R[i] }
        print(String(format: "Pasada de policía (sirena + motor): izquierda − derecha %.1f dB lejos detrás y %.1f dB al cruzar (pasa por la izquierda: debe subir) · golpes VLIT→HRD y claxon",
                     10 * log10(max(1e-9, lE / max(1e-9, rE))), 10 * log10(max(1e-9, lE2 / max(1e-9, rE2)))))

        let out = AudioTests.outDir("sound-test").appendingPathComponent("\(car.uppercased()).wav")
        writeWav(L, R, rate: 48000, to: out)
        let audioSec = Double(L.count) / 48000
        print(String(format: "WAV: %@ (%.1f s, pico %.2f) · coste: lógica %.1f ms + mezcla %.1f ms por segundo de audio (%.2f %% de un núcleo) · %d voces",
                     out.path, audioSec, maxPeak, logicTime / audioSec * 1000, renderTime / audioSec * 1000, (logicTime + renderTime) / audioSec * 100, mixer.voiceCount))

        // Comprobación del sintetizador Ginsu: la RPM que suena (GetCurrentPitch × 120) sigue a la pedida
        if let accel = cs.engine?.spec.accel, let g = lib.gin(accel) {
            let s = GinsuSynth(g)
            var pkt = [Int16](repeating: 0, count: 1024)
            var rows: [String] = []
            var worst: Float = 0
            s.start(g.minFrequency)
            for k in 0...6 {
                let want = g.minFrequency + (g.maxFrequency - g.minFrequency) * Float(k) / 6
                s.update(frequency: want, latencyMs: 60)
                for _ in 0..<40 { _ = s.nextPacket(&pkt) }            // 440 ms para llegar
                let got = s.currentPitch * 120
                worst = max(worst, abs(got - want) / want)
                rows.append(String(format: "%.0f→%.0f", want, got))
            }
            print(String(format: "Ginsu %@: RPM pedida → sintetizada %@ · error máx. %.1f %%", accel, rows.joined(separator: " "), worst * 100))
            ginsuPitchCheck(g, label: accel)
        }
        eng.stop()
    }
}

extension SFXTests {
    /// Periodo dominante (en muestras) de `x` entre `lo` y `hi` por autocorrelación normalizada.
    static func period(_ x: [Float], lo: Int, hi: Int) -> Int {
        var best: Float = -1, bl = lo
        let n = x.count - hi
        guard n > 0 else { return lo }
        for l in lo...hi {
            var s: Float = 0, e0: Float = 0, e1: Float = 0
            for i in 0..<n { s += x[i] * x[i + l]; e0 += x[i] * x[i]; e1 += x[i + l] * x[i + l] }
            let r = s / max(1e-9, (e0 * e1).squareRoot())
            if r > best { best = r; bl = l }
        }
        return bl
    }

    /// Ciclo del motor medido en la salida del sintetizador a RPM fija frente al de la tabla del .GIN.
    static func ginsuPitchCheck(_ g: GinsuData, label: String) {
        var rows: [String] = []
        var worst: Float = 0
        for k in [0.1, 0.35, 0.6, 0.85] as [Float] {
            let want = g.minFrequency + (g.maxFrequency - g.minFrequency) * k
            let s = GinsuSynth(g)
            s.start(want)
            var pkt = [Int16](repeating: 0, count: 1024)
            var out: [Float] = []
            for _ in 0..<60 { let n = s.nextPacket(&pkt); for i in 0..<n { out.append(Float(pkt[i])) } }
            let x = Array(out.suffix(16000))
            let cycle = Float(g.sampleRate) * 120 / want            // muestras por ciclo esperadas
            let p = period(x, lo: Int(cycle * 0.8), hi: Int(cycle * 1.25))
            let got = Float(g.sampleRate) * 120 / Float(p)
            worst = max(worst, abs(got - want) / want)
            rows.append(String(format: "%.0f→%.0f", want, got))
        }
        print(String(format: "Ginsu %@ (salida medida, ciclo por autocorrelación): %@ · error máx. %.1f %%", label, rows.joined(separator: " "), worst * 100))
    }
}
