// Sonido del juego dentro del motor nativo: motores, turbo, nitro, cambios, derrapes, viento, rodadura, golpes,
// sirenas y cláxones, con los bancos del disco (SFXBank.swift) y la lógica de la decomp (EngineSound.swift).
//
// Uso: `SFXWorld.shared.attach(engine)` (App.swift) → se engancha a Engine.frameHooks y suena solo.
//   · Coches del jugador: `localCars` (por defecto el coche de Engine; la pantalla partida puede dar varios). Suenan sin
//     posición (como el juego, con la cámara detrás); con 2+ jugadores, cada uno un poco a su lado.
//   · Oyentes: `listeners` (por defecto la cámara del jugador 1). Con varios, cada sonido 3D usa el oyente más cercano.
//   · Rivales de carrera (RaceSystem) con su motor completo; policía con sirena y motor; tráfico con rumor y cláxones.
// Ajustes (settings.json → "sound": {"enabled": true, "master": 0.8}) y `--sound-off` / `--volume 0…1` al arrancar.
// Mezcla: los mapas de mezcla del juego (SOUND\MIXMAPS) no están descifrados; los niveles por categoría son propios [H].
import Foundation
import AVFoundation
import simd

/// Un oyente (cámara de un jugador).
struct SFXListener {
    var position = float3(0, 0, 0)
    var forward = float3(1, 0, 0)
    var velocity = float3(0, 0, 0)
}

/// Niveles por categoría (lineales). Propios: sustituyen a SOUND\MIXMAPS [H].
enum SFXMix {
    static var engine: Float = 0.62
    static var opponentEngine: Float = 0.75
    static var turbo: Float = 0.55
    static var nitrous: Float = 0.5
    static var shift: Float = 0.6
    static var skid: Float = 0.42
    static var wind: Float = 0.30
    static var road: Float = 0.28
    static var impact: Float = 0.8
    static var siren: Float = 0.55
    static var traffic: Float = 0.35
    static var horn: Float = 0.6
    static var sputter: Float = 0.35
}

// MARK: - Sonido de un coche con física

final class SFXCarSound {
    let lib: SFXLibrary
    let mixer: SFXMixer
    let name: String
    let engine: EngineAudio?
    let turbo: TurboAudio?
    private var accelV: SFXGinsuVoice?, decelV: SFXGinsuVoice?
    private var spoolV: SFXSampleVoice?, nosV: SFXSampleVoice?
    private var skidSideV: SFXSampleVoice?, skidFwdV: SFXSampleVoice?
    private var windLV: SFXSampleVoice?, windRV: SFXSampleVoice?, roadV: SFXSampleVoice?, whineV: SFXSampleVoice?
    private let turboBank: String?, shiftBank: String?, nosBank: String?, skidBank: String?, sweetBank: String?
    private var lastNOS = false, lastNOSEmpty = false
    private var prevVel: float3?
    private var impactCooldown: Float = 0
    private var rng: SplitMix
    var isLocal: Bool
    var localPan: Float = 0
    private(set) var state = SFXCarState()
    /// Para las pruebas: sonidos lanzados por tipo.
    private(set) var events: [String: Int] = [:]
    /// Para las pruebas: lo último que se pidió al motor.
    var lastOut: EngineAudioOut { engine?.out ?? EngineAudioOut() }

    init?(lib: SFXLibrary, mixer: SFXMixer, car: String, isLocal: Bool, seed: UInt64) {
        guard let c = lib.carSounds(car) else { return nil }
        self.lib = lib; self.mixer = mixer; name = car; self.isLocal = isLocal
        rng = SplitMix(seed: seed)
        let engName = c["engine"] as? String
        let espec = engName.flatMap { lib.engines[$0] }.map { EngineAudioSpec(name: engName!, $0) }
        let sspec = ShiftSpec((c["shift"] as? String).flatMap { lib.shifts[$0] })
        if let espec {
            let e = EngineAudio(spec: espec, shift: sspec, isPlayer: isLocal, seed: seed &+ 1)
            engine = e
            if let a = espec.accel, let g = lib.gin(a) {
                e.minGinsuFreq = g.minFrequency
                accelV = SFXGinsuVoice(g, tag: "\(car):accel"); mixer.add(accelV!)
            }
            if let d = espec.decel, let g = lib.gin(d) { decelV = SFXGinsuVoice(g, tag: "\(car):decel"); mixer.add(decelV!) }
        } else { engine = nil }
        let tname = c["turbo"] as? String
        if let t = tname.flatMap({ lib.turbos[$0] }) { turbo = TurboAudio(t); turboBank = t["BankName"] as? String } else { turbo = nil; turboBank = nil }
        shiftBank = sspec.bank
        nosBank = lib.globalBank("nos", 0)
        skidBank = lib.globalBank("skid", 0)
        sweetBank = espec?.sweet
        if let b = turboBank, let s = lib.sample(b, 0) { spoolV = loop(s, "spool") }
        if let b = skidBank {
            if let s = lib.sample(b, 0) { skidSideV = loop(s, "skid-side") }
            if let s = lib.sample(b, 1) { skidFwdV = loop(s, "skid-fwd") }
        }
        if isLocal {
            if let b = lib.globalBank("wind"), let s0 = lib.sample(b, 0), let s1 = lib.sample(b, 1) { windLV = loop(s0, "wind-l"); windRV = loop(s1, "wind-r") }
            if let b = lib.globalBank("roadnoise"), let s = lib.sample(b, 5) { roadV = loop(s, "road") }     // asfalto: Aud_Roadnoise_LOOP 5 [V]
        }
        if let b = lib.miscBank("CAR_TRANNY"), let s = lib.sample(b, 0) { whineV = loop(s, "reverse") }   // marcha atrás [I]
    }

    private func loop(_ s: SFXSample, _ tag: String) -> SFXSampleVoice {
        let v = SFXSampleVoice(s, loop: true, tag: "\(name):\(tag)", startAt: Double(rng.float()) * Double(s.data.count / 2))
        mixer.add(v)
        return v
    }

    func remove() {
        for v in [accelV, decelV, spoolV, nosV, skidSideV, skidFwdV, windLV, windRV, roadV, whineV] as [SFXVoice?] { if let v { mixer.remove(v) } }
    }

    /// Avanza la lógica del sonido. `space`: ganancias L/R, Doppler y filtro de distancia (de SFXWorld).
    func update(_ s: SFXCarState, dt: Float, space: SFXSpace) {
        state = s
        guard dt > 0 else { return }
        engine?.update(s, dt: dt)
        if let e = engine, let t = turbo { t.step(torque: e.out.torque, physRPM: e.physRPM, dt: dt) }
        let catEngine = isLocal ? SFXMix.engine : SFXMix.opponentEngine
        let o = engine?.out ?? EngineAudioOut()
        let nosBoost: Float = s.nos ? 1.04 : 1     // m_NitrousPitchBoost [I]
        let pitch = o.pitchBelowMin * nosBoost * space.doppler
        // Filtro del motor: el de la mezcla (GINSU_LowPassCutoff al desacelerar) y el de distancia, el menor [D: DualGinsu]
        let lp = min(o.lowpass, space.lowpass)
        // Corte de encendido: el juego cambia a la muestra de corte AEMS (no portada); aquí se modula el volumen [H]
        var limiter: Float = 1
        if s.onLimiter, isLocal { limiter = 0.75 + 0.25 * (sinf(Float(CACurrentMediaTimeShim.now()) * 2 * .pi * 11) > 0 ? 1 : 0) }
        let shiftPunch: Float = 1
        mixer.withLock {
            // La parte AEMS va al .GIN de desaceleración dentro de su banda y al de aceleración fuera (suma de potencias) [H]
            let toDecel = decelV != nil ? o.decelCross * (1 - min(1, o.torque / 35)) : 0
            let aemsA = o.aemsGain * (1 - toDecel), aemsD = o.aemsGain * toDecel
            let gA = (o.accelGain * o.accelGain + aemsA * aemsA).squareRoot(), gD = (o.decelGain * o.decelGain + aemsD * aemsD).squareRoot()
            if let v = accelV { set(v, gain: gA * catEngine * limiter * shiftPunch, space, pitch: pitch, lp: lp); v.params.ginsuFreq = o.ginsuFreq }
            if let v = decelV { set(v, gain: gD * catEngine, space, pitch: pitch, lp: lp); v.params.ginsuFreq = o.ginsuFreq }
            if let v = spoolV, let t = turbo {
                set(v, gain: t.spoolGain * SFXMix.turbo, space, pitch: (0.55 + 0.75 * t.spoolPercent) * space.doppler, lp: space.lowpass)
            }
            // Derrapes [H: umbrales y curvas propias; el juego los pasa por el mezclador dinámico]
            let ground: Float = s.wheelsOnGround > 0 ? 1 : 0
            let side = min(1, max(0, (s.slipSide - 1.2) / 5)) * ground
            let fwd = min(1, max(0, (s.slipForward - 2.0) / 7)) * ground
            if let v = skidSideV { set(v, gain: side * SFXMix.skid, space, pitch: (0.9 + 0.2 * side) * space.doppler, lp: space.lowpass) }
            if let v = skidFwdV { set(v, gain: fwd * SFXMix.skid, space, pitch: (0.9 + 0.2 * fwd) * space.doppler, lp: space.lowpass) }
            let mph = s.speedMPH
            if let l = windLV, let r = windRV {
                let w = powf(min(1, max(0, (mph - 15) / 110)), 1.5) * SFXMix.wind
                l.params.gainL = w; l.params.gainR = w * 0.25; l.params.pitch = 0.8 + 0.4 * min(1, mph / 150)
                r.params.gainL = w * 0.25; r.params.gainR = w; r.params.pitch = 0.82 + 0.4 * min(1, mph / 150)
            }
            if let v = roadV {
                let g = min(1, mph / 70) * SFXMix.road * ground
                v.params.gainL = g; v.params.gainR = g; v.params.pitch = 0.7 + 0.6 * min(1, mph / 130)
            }
            if let v = whineV {
                let rev = s.gear == Gear.reverse ? min(1, s.speed / 6) : 0
                set(v, gain: rev * 0.3, space, pitch: 0.6 + 0.8 * min(1, s.speed / 12), lp: space.lowpass)
            }
        }
        // Nitro: entrada + bucle, cierre al soltar; purga cuando se vacía [D: CARSFX_Nitrous]
        if let b = nosBank {
            if s.nos && !lastNOS {
                if let st = lib.sample(b, 1) { oneShot(st, gain: SFXMix.nitrous, space); events["nitro", default: 0] += 1 }
                if let lp = lib.sample(b, 0) { nosV = SFXSampleVoice(lp, loop: true, tag: "\(name):nos"); mixer.add(nosV!) }
            }
            if !s.nos && lastNOS {
                if let v = nosV { mixer.remove(v); nosV = nil }
                if let st = lib.sample(b, 2) { oneShot(st, gain: SFXMix.nitrous * 0.8, space) }
            }
            if let v = nosV { mixer.withLock { set(v, gain: SFXMix.nitrous, space, pitch: space.doppler, lp: space.lowpass) } }
        }
        lastNOS = s.nos; lastNOSEmpty = s.nosEmpty
        // Cambios de marcha
        if let e = engine, let b = shiftBank {
            for p in e.pendingShiftSounds { if let st = lib.sample(b, p.sample) { oneShot(st, gain: p.vol * SFXMix.shift, space, delay: p.delay); events[p.sample == 1 ? "cambio arriba" : "cambio abajo", default: 0] += 1 } }
            e.pendingShiftSounds.removeAll()
            // Petardeos (CAR_Sputter / sweeteners SWTN_CAR_NN)
            if e.pendingSputters > 0, let sb = sweetBank {
                let n = lib.soundCount(sb)
                var delay: Float = 0
                for _ in 0..<min(3, e.pendingSputters) where n > 0 {
                    if let st = lib.sample(sb, Int(rng.next() % UInt64(n))) { oneShot(st, gain: (e.spec.sputterVol / 32767) * SFXMix.sputter, space, delay: delay); events["petardeo", default: 0] += 1 }
                    delay += 0.07 + 0.12 * rng.float()
                }
                e.pendingSputters = 0
            }
        }
        // Descarga del turbo
        if let t = turbo, let b = turboBank, let bo = t.pendingBlowoff {
            if lib.soundCount(b) > bo.id, let st = lib.sample(b, bo.id) { oneShot(st, gain: bo.vol * SFXMix.turbo * 1.3, space); events["descarga turbo", default: 0] += 1 }
            t.pendingBlowoff = nil
        }
        // Golpes: salto brusco de velocidad (la física no avisa de los choques con la IA) [I]
        impactCooldown -= dt
        if let pv = prevVel, impactCooldown <= 0 {
            let dv = s.velocity - pv
            let dh = simd_length(SIMD2(dv.x, dv.y)) - 9.81 * dt * 0.0
            let dz = dv.z
            // Los golpes contra coches y rompibles ya los toca el sistema de choques (Crash/CrashWorld.swift CrashSounds)
            if (dh > 2.2 * (dt * 60) || dz > 6) && !CrashSounds.playedRecently(near: s.position) {
                let fwdHit = abs(simd_dot(simd_normalize(SIMD2(dv.x, dv.y) + 1e-6), simd_normalize(SIMD2(s.forward.x, s.forward.y) + 1e-6))) > 0.7
                let mag = max(dh / (dt * 60), dz * 0.6)
                let level = mag < 4 ? "VLIT" : mag < 7 ? "LIT" : mag < 11 ? "MED" : "HRD"
                let what = dz > 6 && dh < 2.2 ? "CRSH_CAR_BOTM_\(level)" : "CRSH_CAR_2_\(SFXWorld.shared.nearCar(s.position) ? "CAR" : "WALL")_\(fwdHit ? "FRNT" : "SIDE")_\(level)"
                SFXWorld.shared.playStitch(prefix: what, space: space, rng: &rng)
                events["golpe \(level)", default: 0] += 1
                impactCooldown = 0.25
            }
        }
        prevVel = s.velocity
    }

    private func set(_ v: SFXVoice, gain: Float, _ sp: SFXSpace, pitch: Float, lp: Float) {
        v.params.gainL = gain * sp.gainL; v.params.gainR = gain * sp.gainR; v.params.pitch = pitch; v.params.lowpass = lp
    }

    func oneShot(_ s: SFXSample, gain: Float, _ sp: SFXSpace, delay: Float = 0, pitch: Float = 1) {
        let v = SFXSampleVoice(s, loop: false, tag: "\(name):shot", delaySamples: Int(delay * Float(mixer.outRate)))
        v.params.gainL = gain * sp.gainL; v.params.gainR = gain * sp.gainR; v.params.pitch = pitch * sp.doppler; v.params.lowpass = sp.lowpass
        mixer.add(v)
    }
}

/// Resultado del posicionamiento de un sonido respecto al oyente.
struct SFXSpace {
    var gainL: Float = 0.707, gainR: Float = 0.707
    var doppler: Float = 1
    var lowpass: Float = 24000
    var distance: Float = 0
    static let local = SFXSpace()
}

// MARK: - Mundo

final class SFXWorld {
    static let shared = SFXWorld()

    struct Settings: Codable { var enabled = true; var master: Float = 0.8 }
    private(set) var settings = Settings()
    private(set) var lib: SFXLibrary?
    private(set) var mixer: SFXMixer?
    private var avEngine: AVAudioEngine?
    private weak var engine: Engine?
    private var triedRoot: URL?

    /// Coches de los jugadores en esta máquina (pantalla partida: varios). Por defecto, el de Engine.
    var localCarsProvider: (() -> [Car])?
    /// Oyentes (una cámara por jugador). Por defecto, la cámara de Engine.
    var listenersProvider: (() -> [SFXListener])?

    private var carSounds: [ObjectIdentifier: SFXCarSound] = [:]
    private var copEngines: [Int: (voice: SFXGinsuVoice, rpm: Float)] = [:]
    private var sirens: [Int: (voice: SFXSampleVoice, wail: Bool, switchAt: Float)] = [:]
    private var traffic: [Int: SFXSampleVoice] = [:]
    private var hornCooldown: [Int: Float] = [:]
    private var listeners: [SFXListener] = [SFXListener()]
    private var lastListenerPos: float3?
    private var clock: Float = 0
    private var rng = SplitMix(seed: 0xA0D10)
    private var stitchByName: [String: [Int]] = [:]
    private var aiPositions: [float3] = []

    private init() {
        if let d = try? Data(contentsOf: LightBar.settingsURL),
           let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let r = root["sound"],
           let raw = try? JSONSerialization.data(withJSONObject: r), let s = try? JSONDecoder().decode(Settings.self, from: raw) { settings = s }
        let a = CommandLine.arguments
        if a.contains("--sound-off") { settings.enabled = false }
        if let i = a.firstIndex(of: "--volume"), i + 1 < a.count, let v = Float(a[i + 1]) { settings.master = max(0, min(1, v)) }
    }

    // MARK: Ajustes (para el menú de opciones)

    func setEnabled(_ on: Bool) { settings.enabled = on; mixer?.muted = !on; save() }
    func setMasterVolume(_ v: Float) { settings.master = max(0, min(1, v)); mixer?.master = settings.master; save() }
    private func save() {
        let url = LightBar.settingsURL
        var root = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        root["sound"] = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))) ?? [:]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    // MARK: Arranque

    /// Carga sound/ y engancha el sonido a los fotogramas del motor (una vez).
    func attach(_ e: Engine) {
        guard engine !== e else { return }
        engine = e
        guard prepare(root: e.data.root, outRate: 48000) else { return }
        startOutput()
        e.frameHooks.append { [weak self, weak e] dt in
            guard let self, let e else { return }
            self.mixer?.muted = !self.settings.enabled || e.ui?.paused == true
            self.update(engine: e, dt: dt)
        }
    }

    /// Carga la biblioteca y crea el mezclador (sin salida de audio: las pruebas renderizan a mano).
    @discardableResult
    func prepare(root: URL, outRate: Double) -> Bool {
        if lib == nil || triedRoot != root {
            triedRoot = root
            lib = SFXLibrary(root: root)
            if lib == nil { print("Sonido: no hay \(root.path)/sound (vuelve a convertir el disco)"); return false }
            stitchByName = [:]
            for (i, s) in lib!.stitches.enumerated() {
                guard let n = s?["name"] as? String else { continue }
                stitchByName[String(n.reversed().drop(while: { $0.isNumber }).reversed()), default: []].append(i)
            }
            print("Sonido: \(lib!.bankCount) bancos, \(lib!.gins.count) motores, \(lib!.cars.count) coches · volumen \(Int(settings.master * 100)) %\(settings.enabled ? "" : " (apagado)")")
        }
        if mixer == nil { let m = SFXMixer(outRate: outRate); m.master = settings.master; m.muted = !settings.enabled; mixer = m }
        return true
    }

    func startOutput() {
        guard let m = mixer, avEngine == nil else { return }
        let e = AVAudioEngine()
        let node = m.makeNode()
        e.attach(node)
        e.connect(node, to: e.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: m.outRate, channels: 2))
        do { try e.start(); avEngine = e } catch { fputs("Sonido: AVAudioEngine no arranca: \(error.localizedDescription)\n", stderr) }
    }
    /// ¿Está sonando por la salida del Mac? (pruebas)
    var isRunning: Bool { avEngine?.isRunning == true }

    // MARK: Por fotograma

    private func update(engine e: Engine, dt: Float) {
        // Oyentes
        if let lp = listenersProvider?(), !lp.isEmpty { listeners = lp }
        else {
            var l = SFXListener()
            l.position = e.eye
            if e.mode == .drive { l.forward = simd_normalize(e.chaseTarget - e.chasePos + float3(0, 0, 1e-4)) }
            else { l.forward = float3(cos(e.pitch) * cos(e.yaw), cos(e.pitch) * sin(e.yaw), sin(e.pitch)) }
            if let p = lastListenerPos, dt > 0 { l.velocity = (l.position - p) / dt }
            lastListenerPos = l.position
            listeners = [l]
        }
        // Coches con física: jugadores + rivales de la carrera
        var physCars: [(Car, Bool)] = []
        let locals = localCarsProvider?() ?? (e.mode == .drive ? e.car.map { [$0] } ?? [] : [])
        for c in locals { physCars.append((c, true)) }
        if let rs = RaceSystem.shared?.session?.racers {
            let near = rs.filter { !$0.isPlayer }.map(\.car).filter { c in !locals.contains { $0 === c } }
                .sorted { listenerDistance($0.position) < listenerDistance($1.position) }.prefix(4)
            for c in near { physCars.append((c, false)) }
        }
        aiPositions = (e.ai?.vehicles.map(\.pos) ?? []) + physCars.map { $0.0.position }
        var seen = Set<ObjectIdentifier>()
        for (i, (car, local)) in physCars.enumerated() {
            guard let v = car.vehicle else { continue }
            let id = ObjectIdentifier(car)
            seen.insert(id)
            if carSounds[id] == nil, let lib, let mixer {
                carSounds[id] = SFXCarSound(lib: lib, mixer: mixer, car: car.specs?.model ?? "", isLocal: local, seed: UInt64(i + 1) &* 7919)
                    ?? SFXCarSound(lib: lib, mixer: mixer, car: Config.playerCar, isLocal: local, seed: UInt64(i + 1))
            }
            guard let cs = carSounds[id] else { continue }
            var st = SFXCarState(vehicle: v)
            st.position = car.position
            let sp: SFXSpace
            if local {
                var s = SFXSpace.local
                if locals.count > 1 { let pan: Float = locals.count == 2 ? (i == 0 ? -0.35 : 0.35) : 0; s = SFXWorld.panned(pan) }
                sp = s
            } else { sp = space(at: car.position, velocity: car.velocity, ref: 10) }
            cs.update(st, dt: dt, space: sp)
        }
        for (id, cs) in carSounds where !seen.contains(id) { cs.remove(); carSounds[id] = nil }
        if let ai = e.ai { updateAI(ai, dt: dt) }
        clock += dt
    }

    /// Pruebas: fija los oyentes a mano.
    func setListeners(_ l: [SFXListener]) { listeners = l }

    func listenerDistance(_ p: float3) -> Float { listeners.map { simd_distance($0.position, p) }.min() ?? 0 }
    /// ¿Hay otro coche pegado a `p`? (golpe coche contra coche).
    func nearCar(_ p: float3) -> Bool { aiPositions.contains { let d = simd_distance($0, p); return d > 0.5 && d < 6 } }

    static func panned(_ pan: Float) -> SFXSpace {
        var s = SFXSpace()
        let a = (pan + 1) * .pi / 4
        s.gainL = cosf(a); s.gainR = sinf(a)
        return s
    }

    /// Ganancia (distancia, lado), Doppler y filtro de distancia respecto al oyente más cercano.
    func space(at p: float3, velocity: float3, ref: Float, maxDistance: Float = 400) -> SFXSpace {
        guard let l = listeners.min(by: { simd_distance($0.position, p) < simd_distance($1.position, p) }) else { return SFXSpace.local }
        var s = SFXSpace()
        let d = p - l.position
        let dist = simd_length(d)
        s.distance = dist
        let att = dist <= ref ? 1 : ref / dist
        let fade = dist > maxDistance * 0.75 ? max(0, 1 - (dist - maxDistance * 0.75) / (maxDistance * 0.25)) : 1
        let n = dist > 0.01 ? d / dist : l.forward
        let right = simd_normalize(simd_cross(l.forward, float3(0, 0, 1)) + 1e-6)
        let pan = max(-1, min(1, simd_dot(n, right))) * 0.85
        let a = (pan + 1) * .pi / 4
        s.gainL = cosf(a) * att * fade; s.gainR = sinf(a) * att * fade
        // Doppler (c = 343 m/s, a la mitad para que no exagere) [H]
        let c: Float = 343
        let vl = simd_dot(l.velocity, n), vs = simd_dot(velocity, n)
        s.doppler = max(0.6, min(1.6, 1 + ((c + vl) / max(30, c + vs) - 1) * 0.5))
        // Filtro por distancia de SFXCTL_Engine::UpdateFilterFX (6,5 m → 725 Hz a 50,5 m) [D, curva aproximada]
        let f = min(1, max(0, (dist - 6.5) / 44))
        s.lowpass = 725 + 23275 * (1 - f) * (1 - f)
        return s
    }

    // MARK: IA: policía (sirena, motor) y tráfico (rumor, cláxones)

    private func updateAI(_ ai: AIWorld, dt: Float) {
        guard let lib, let mixer else { return }
        let siren = lib.miscBank("SIREN_MB"), trafficBank = lib.miscBank("TRAFFIC_MB")
        let cops = ai.vehicles.filter { $0.kind == .cop }.sorted { listenerDistance($0.pos) < listenerDistance($1.pos) }
        // Sirenas: las 4 más cercanas con las luces puestas; alternan wail / yelp cada 4–8 s [H]
        let sirenCops = cops.filter { $0.lights && listenerDistance($0.pos) < 500 }.prefix(4)
        let sirenIDs = Set(sirenCops.map(\.id))
        for (id, s) in sirens where !sirenIDs.contains(id) { mixer.remove(s.voice); sirens[id] = nil }
        for c in sirenCops {
            guard let b = siren else { break }
            if sirens[c.id] == nil || clock > sirens[c.id]!.switchAt {
                let wail = sirens[c.id].map { !$0.wail } ?? (rng.float() < 0.7)
                if let old = sirens[c.id] { mixer.remove(old.voice) }
                if let smp = lib.sample(b, wail ? 2 : 0) {
                    let v = SFXSampleVoice(smp, loop: true, tag: "siren\(c.id)", startAt: Double(rng.float()) * Double(smp.data.count / 2))
                    mixer.add(v)
                    sirens[c.id] = (v, wail, clock + (wail ? 5 : 2.5) + 3 * rng.float())
                }
            }
            if let s = sirens[c.id] {
                let sp = space(at: c.pos + float3(0, 0, 1.5), velocity: c.fwd * c.speed, ref: 18, maxDistance: 500)
                mixer.withLock { s.voice.params.gainL = sp.gainL * SFXMix.siren; s.voice.params.gainR = sp.gainR * SFXMix.siren; s.voice.params.pitch = sp.doppler; s.voice.params.lowpass = max(2500, sp.lowpass) }
            }
        }
        // Motores de la policía: los 3 más cercanos a < 150 m, con un cambio de marchas simulado por la velocidad [H]
        let engCops = cops.filter { listenerDistance($0.pos) < 150 }.prefix(3)
        let engIDs = Set(engCops.map(\.id))
        for (id, ce) in copEngines where !engIDs.contains(id) { mixer.remove(ce.voice); copEngines[id] = nil }
        for c in engCops {
            if copEngines[c.id] == nil, let cs = lib.carSounds(c.typeName), let en = cs["engine"] as? String,
               let accel = lib.engines[en]?["Filename_GinsuAccel"] as? String, let g = lib.gin(accel) {
                let v = SFXGinsuVoice(g, tag: "cop\(c.id)"); mixer.add(v); copEngines[c.id] = (v, g.minFrequency)
            }
            guard let ce = copEngines[c.id] else { continue }
            let g = ce.voice.voice.synth.data
            let sp = space(at: c.pos, velocity: c.fwd * c.speed, ref: 10, maxDistance: 150)
            let kmh = c.speed * 3.6
            let gearSpan: Float = 45
            let inGear = kmh < 5 ? 0 : (kmh.truncatingRemainder(dividingBy: gearSpan)) / gearSpan
            let rpm = g.minFrequency + (g.maxFrequency - g.minFrequency) * (kmh < 5 ? 0.02 : 0.35 + 0.55 * inGear)
            mixer.withLock {
                ce.voice.params.ginsuFreq = rpm
                ce.voice.params.gainL = sp.gainL * SFXMix.opponentEngine * 0.6; ce.voice.params.gainR = sp.gainR * SFXMix.opponentEngine * 0.6
                ce.voice.params.pitch = sp.doppler; ce.voice.params.lowpass = sp.lowpass
            }
        }
        // Tráfico: rumor de motor de los 6 más cercanos a < 70 m; claxon si el jugador pasa rozando y rápido [H]
        guard let tb = trafficBank else { return }
        let near = ai.vehicles.filter { $0.kind == .traffic && listenerDistance($0.pos) < 70 }
            .sorted { listenerDistance($0.pos) < listenerDistance($1.pos) }.prefix(6)
        let ids = Set(near.map(\.id))
        for (id, v) in traffic where !ids.contains(id) { mixer.remove(v); traffic[id] = nil }
        let player = engine?.car
        for t in near {
            if traffic[t.id] == nil, let smp = lib.sample(tb, t.id % 2) {
                let v = SFXSampleVoice(smp, loop: true, tag: "traffic\(t.id)", startAt: Double(rng.float()) * Double(smp.data.count / 2))
                mixer.add(v); traffic[t.id] = v
            }
            if let v = traffic[t.id] {
                let sp = space(at: t.pos, velocity: t.fwd * t.speed, ref: 8, maxDistance: 70)
                let g = (0.25 + 0.75 * min(1, t.speed / 20)) * SFXMix.traffic
                mixer.withLock { v.params.gainL = sp.gainL * g; v.params.gainR = sp.gainR * g; v.params.pitch = (0.8 + 0.4 * min(1, t.speed / 25)) * sp.doppler; v.params.lowpass = sp.lowpass }
            }
            hornCooldown[t.id] = (hornCooldown[t.id] ?? 0) - dt
            if let p = player, (hornCooldown[t.id] ?? 0) <= 0, abs(p.speed) > 18, simd_distance(p.position, t.pos) < 9, rng.float() < 0.35 {
                let truck = (lib.carSounds(t.typeName)?["horn"] as? Int ?? 5) == 11
                if let smp = lib.sample(tb, truck ? 3 : 2) {
                    let sp = space(at: t.pos, velocity: t.fwd * t.speed, ref: 12, maxDistance: 120)
                    let v = SFXSampleVoice(smp, loop: false, tag: "horn\(t.id)", delaySamples: Int(Float(mixer.outRate) * 0.15 * rng.float()))
                    v.params.gainL = sp.gainL * SFXMix.horn; v.params.gainR = sp.gainR * SFXMix.horn; v.params.pitch = sp.doppler
                    mixer.add(v)
                }
                hornCooldown[t.id] = 6
            } else if (hornCooldown[t.id] ?? 0) <= 0 { hornCooldown[t.id] = 0.5 }
        }
    }

    // MARK: Golpes

    /// Toca un «stitch» de golpe (prefijo sin el número final: CRSH_CAR_2_WALL_FRNT_MED…) [D: STICH_PlayBack, datos de INGAMEB.BUN].
    func playStitch(prefix: String, space sp: SFXSpace, rng: inout SplitMix) {
        guard let lib, let mixer, let bank = lib.globalBank("stitch", 0), let list = stitchByName[prefix], !list.isEmpty,
              let st = lib.stitches[list[Int(rng.next() % UInt64(list.count))]], let refs = st["refs"] as? [[Int]] else { return }
        let vol = Float(st["volume"] as? Int ?? 32767) / 32767
        for r in refs where r.count >= 7 {
            guard let smp = lib.sample(bank, r[0]) else { continue }
            let rv = Float(r[1] - Int(rng.next() % UInt64(max(1, r[4] + 1)))) / 32767
            let rp = Float(r[2] + Int(Float(r[5]) * rng.float())) / 4096
            let v = SFXSampleVoice(smp, loop: false, tag: "stitch", delaySamples: Int(Double(r[3]) / 1000 * mixer.outRate))
            let g = max(0, rv) * vol * SFXMix.impact
            v.params.gainL = g * sp.gainL; v.params.gainR = g * sp.gainR; v.params.pitch = max(0.25, rp) * sp.doppler; v.params.lowpass = sp.lowpass
            mixer.add(v)
        }
    }
}
