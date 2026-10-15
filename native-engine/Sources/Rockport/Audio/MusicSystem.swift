// Música del juego en el motor nativo (doc 25): EA Trax en menús y zona libre, música interactiva en las persecuciones y
// ambientes por zona, con la lógica de la decomp:
//   · SFXObj_PFEATrax (EAXSound/CARSFX/SFXObj_Pathfinder.cpp) [D]: tipo de música (SPLASH, LICENCED, INTERACTIVE, AMBIENCE),
//     lista del jugador por estado (FE menús / IG juego, DefPlay FE·IG·AL), siguiente canción sin repetir (en orden o al azar),
//     paso a la persecución (TestToPursuit), ambiente de 40 s tras la persecución (PURSUIT_TO_LIC_DELAY), ambiente por zona
//     (ParameterMap «Ambience» en el juego; refugio 9, taller 10, menú 11, concesionario 12 en los menús), proyecto
//     interactivo siguiente al volver a las canciones (SwapInteractiveProjects).
//   · Speech/MusicFlow.cpp [D]: estados NEUTRAL / LOSE / WIN / ELUDE / TERMINAL con sus reglas e intensidad (media 0,99/0,01),
//     que se manda cada actualización × 127 como PATH_control; los eventos 10–15 y 17 (PFXMAP) cambian de parte.
//   · Niveles del mapa de mezcla MAPOUTPUT, estado MUSIC (MusicMix) y «Speech Ducker» con la radio de la policía.
// Ajustes: settings.json → "music": {"volume", "interactive", "eaTrax", "shuffle", "playlist": {"<nº>": "FE|IG|AL|OFF"}};
// al arrancar `--music-off` y `--music-volume V`.
import Foundation
import simd

/// Lo que la música necesita saber del juego en cada momento (lo rellena el motor o, sin ventana, la prueba).
struct MusicWorld {
    enum Place: Equatable { case none, splash, frontend(zone: Int), game }
    enum Pursuit { case inactive, active, searching }
    var place: Place = .none
    var carPosition: float2?
    var pursuit: Pursuit = .inactive
    var cooldown = false
    var busted = false
    /// Velocidad del jugador (mph) y punta del coche (mph, 160 si no se sabe [D: MessageInitFlow]).
    var playerSpeedMPH: Float = 0
    var topSpeedMPH: Float = 160
    /// Distancia al policía de la persecución más cercano (m; −1 si no hay).
    var pursuitDistance: Float = -1
    var perpLostTime: Float = 0
    var timeLastCrashed: Float = 99
    var timeLastNailedCop: Float = 99
    var collapseActive = false
    var timeUntilBusted: Float = 5
    var highIntensity = false
    /// La radio de la policía habla («Speech Ducker»).
    var speech = false
    /// Carrera de aceleración o D-Day: sin canciones (TestToLicensed) [D].
    var noLicensed = false
    var splitScreen = false
}

final class MusicSystem: MusicTrackDelegate {
    static let shared = MusicSystem()

    struct Settings: Codable {
        var volume: Float = 0.8
        /// Música interactiva en las persecuciones (InteractiveMusicMode).
        var interactive = true
        /// Canciones de EA Trax (EATraxMode).
        var eaTrax = true
        /// Lista al azar (PBMode 1) o en orden.
        var shuffle = true
        /// Canción (nº de music.json) → "FE", "IG", "AL" u "OFF". Lo que falte usa el DefPlay del juego.
        var playlist: [String: String] = [:]
    }
    private(set) var settings = Settings()

    enum MusicType: String { case none, splash, licensed, interactive, ambience }
    private(set) var type: MusicType = .none
    private(set) var lib: MusicLibrary?
    private(set) var output: MusicOutput?
    private var licensed: MusicTrack?
    private var interactive: [MusicTrack] = []
    private(set) var interactiveIndex = 0
    private var ambienceMap: AmbienceMap?
    private var triedRoot: URL?
    private weak var engine: Engine?
    private var lastWall = CACurrentMediaTimeShim.now()
    private var flowAccum: Double = 0
    private(set) var clock: Double = 0
    private var moviePaused = false

    // EA Trax
    private var playBits: [Bool: Set<Int>] = [:]          // FE (true) / IG (false) → canciones que quedan por sonar
    private var lastSong: [Bool: Int] = [:]
    private(set) var currentSong: MusicSong?
    private var ambienceStart: Double = -1000
    private var interactiveStart: Double = 0
    private(set) var ambienceZone = -1
    private var lastPlaceFE: Bool?
    private var rng = SplitMix(seed: UInt64(Date().timeIntervalSince1970))
    let flow = MusicFlow()
    var world = MusicWorld()
    /// Registro de cambios (pruebas) y avisos.
    var trace: ((String) -> Void)?
    var log: (String) -> Void = { print($0) }

    private init() {
        if let d = try? Data(contentsOf: LightBar.settingsURL),
           let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let r = root["music"],
           let raw = try? JSONSerialization.data(withJSONObject: r), let s = try? JSONDecoder().decode(Settings.self, from: raw) { settings = s }
        let a = CommandLine.arguments
        if a.contains("--music-off") { settings.volume = 0 }
        if let i = a.firstIndex(of: "--music-volume"), i + 1 < a.count, let v = Float(a[i + 1]) { settings.volume = max(0, min(1, v)) }
        flow.system = self
    }

    // MARK: Ajustes

    func setVolume(_ v: Float) { settings.volume = max(0, min(1, v)); save() }
    func setInteractive(_ on: Bool) { settings.interactive = on; save() }
    func setEATrax(_ on: Bool) { settings.eaTrax = on; save() }
    func setShuffle(_ on: Bool) { settings.shuffle = on; save() }
    /// Dónde suena una canción: "FE", "IG", "AL" u "OFF" (nil = lo del juego).
    func setPlaylist(song: Int, _ mode: String?) { settings.playlist[String(song)] = mode; playBits = [:]; save() }
    private func save() {
        let url = LightBar.settingsURL
        var root = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        root["music"] = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))) ?? [:]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    // MARK: Arranque

    /// Carga music/ (sin salida de audio: las pruebas la mezclan a mano).
    @discardableResult
    func prepare(root: URL) -> Bool {
        if triedRoot == root { return lib != nil }
        triedRoot = root
        guard let l = MusicLibrary(root: root) else { log("Música: no hay \(root.path)/music (vuelve a convertir el disco)"); return false }
        lib = l
        let out = MusicOutput()
        output = out
        let lt = MusicTrack(project: l.licensed, channel: out.makeChannel())
        lt.delegate = self
        licensed = lt
        interactive = l.interactive.map { p in let t = MusicTrack(project: p, channel: out.makeChannel()); t.delegate = self; t.control = 0; return t }
        interactiveIndex = Int(rng.next() % UInt64(max(1, interactive.count)))   // uno de los 4 al azar al empezar [D]
        ambienceMap = AmbienceMap(root: root)
        log("Música: \(l.songs.count) canciones, \(l.projects.count) proyectos PathFinder (persecución: \(interactive[safe: interactiveIndex]?.project.name ?? "—")) · mezcla \(l.mix.fromFile ? "MAPOUTPUT" : "propia") · volumen \(Int(settings.volume * 100)) %")
        return true
    }

    /// Engancha la música a los fotogramas del motor (una vez).
    func attach(_ e: Engine) {
        guard engine !== e else { return }
        engine = e
        guard prepare(root: e.data.root) else { return }
        output?.start()
        e.frameHooks.append { [weak self, weak e] _ in
            guard let self, let e else { return }
            self.world = MusicSystem.observe(e)
            self.tick()
        }
    }

    /// Lo que pasa en el juego, leído del motor (solo lectura).
    static func observe(_ e: Engine) -> MusicWorld {
        var w = MusicWorld()
        if let ui = e.ui {
            switch ui.state {
            case .splash: w.place = .splash
            case .menu, .garage:
                var zone = 11
                if let st = e.garages?.stage, st.active {
                    switch st.kind { case .safehouse: zone = 9; case .customShop, .backroom: zone = 10; case .carLot: zone = 12; case .mainFE: zone = 11 }
                }
                if ui.state == .garage, let k = e.garages?.world?.current?.kind {
                    switch k { case .safehouse: zone = 9; case .customShop, .backroom: zone = 10; case .carLot: zone = 12; case .mainFE: zone = 11 }
                }
                w.place = .frontend(zone: zone)
            case .game, .pause, .modal: w.place = .game
            }
        } else { w.place = e.mode == .drive ? .game : .none }
        if let car = e.car {
            w.carPosition = float2(car.position.x, car.position.y)
            w.playerSpeedMPH = simd_length(car.velocity) * 2.23694
        }
        if let ai = e.ai, let pol = ai.police {
            switch pol.state {
            case .chase: w.pursuit = .active
            case .cooldown: w.pursuit = .searching; w.cooldown = true
            case .busted: w.busted = true
            case .none, .evaded: break
            }
            let p = ai.player.pos
            let cops = ai.vehicles.filter { $0.kind == .cop && $0.copRole == .pursuit }
            w.pursuitDistance = cops.map { simd_distance($0.pos, p) }.min() ?? -1
            w.perpLostTime = pol.timeSinceSeen
            w.collapseActive = pol.bustTimer > 0
            w.timeUntilBusted = PoliceManager.bustedTimeout - pol.bustTimer
            w.highIntensity = pol.heat >= 4
        }
        w.speech = PoliceRadio.shared.isBusy
        if let ev = RaceSystem.shared?.session?.event { w.noLicensed = ev.kind == .drag }
        w.splitScreen = e.splitScreen?.active == true
        return w
    }

    // MARK: Por fotograma

    /// Película en pantalla: la música espera (Movies/Movies.swift lo llama mientras dura).
    func setMoviePlaying(_ on: Bool) {
        moviePaused = on
        output?.set(gain: currentGain(), lowpass: 65535, paused: on)
    }

    /// Paso del juego con reloj real (también en pausa: la música sigue).
    func tick() {
        let now = CACurrentMediaTimeShim.now()
        let dt = min(0.25, now - lastWall)
        lastWall = now
        step(dt: dt)
    }

    /// Avanza `dt` segundos (la prueba sin ventana lo llama con su reloj).
    func step(dt: Double) {
        guard lib != nil, let licensed else { return }
        if moviePaused && !Movies.shared.isPlaying { moviePaused = false }
        clock += dt
        // MusicFlow a 30 Hz (una actualización por fotograma del PS2) [H: el juego la llama cada fotograma]
        flowAccum += dt
        while flowAccum >= 1.0 / 30 {
            flowAccum -= 1.0 / 30
            if type == .interactive { flow.update(world, settings: settings) }
        }
        if type == .interactive, let t = interactive[safe: interactiveIndex] { t.control = flow.control }
        updateMusicType()
        licensed.update(dt: dt)
        for t in interactive { t.update(dt: dt) }
        output?.set(gain: currentGain(), lowpass: 65535, paused: moviePaused)
    }

    private var duckGain: Float = 1

    private func currentGain() -> Float {
        guard let lib else { return 0 }
        let fe: Bool
        switch world.place { case .frontend, .splash: fe = true; default: fe = false }
        let m = lib.mix
        let level: Float
        switch type {
        case .licensed, .splash: level = fe ? m.licensedFE : m.licensedIG
        case .interactive: level = fe ? m.composedFE : m.composedIG
        case .ambience: level = fe ? m.ambienceFE : m.ambienceIG
        case .none: level = 0
        }
        // Voz de la radio: «Speech Ducker» con subida y bajada suaves
        let duckTarget = world.speech && !fe ? MusicMix.gain(m.speechDuck) : 1
        duckGain += (duckTarget - duckGain) * 0.15
        // 0,5: el nivel de referencia de la música frente a los efectos (SFXMix) [H]
        return settings.volume * MusicMix.gain(level) * duckGain * 0.5
    }

    // MARK: Tipo de música (UpdateInGame / TestTo* de SFXObj_PFEATrax)

    private func updateMusicType() {
        guard let licensed else { return }
        let w = world
        switch w.place {
        case .none:
            return
        case .splash:
            if type != .splash {
                stopInteractive()
                type = .splash; currentSong = nil
                licensed.setVar(named: "rapsheet", 0)
                licensed.event(0x01C53FC7)   // EVT_STARTSCREEN → SPLASH [D]
                trace?("tipo → SPLASH (pantalla de inicio)")
            }
            return
        case .frontend(let zone):
            stopInteractive()
            let fe = true
            if lastPlaceFE != fe { lastPlaceFE = fe; songFitsPlace(fe) }
            if settings.eaTrax, settings.volume > 0, !songs(fe: true).isEmpty {
                if type != .licensed || !licensed.isPlaying { startLicensed() }
            } else if type != .ambience || ambienceZone != zone || !licensed.isPlaying { startAmbience(zone) }
        case .game:
            if lastPlaceFE != false { lastPlaceFE = false; songFitsPlace(false) }
            let zone = w.carPosition.flatMap { p in ambienceMap?.zone(x: p.x, y: p.y) } ?? 0
            switch type {
            case .interactive:
                let trackPlaying = interactive[safe: interactiveIndex]?.isPlaying ?? false
                if !settings.interactive || settings.volume == 0 || ((!flow.musicActive || w.pursuit == .inactive) && !trackPlaying && clock - interactiveStart > 2) {
                    // Fin de la persecución: ambiente y, a los 40 s, canciones [D: TestToAmbience, PURSUIT_TO_LIC_DELAY]
                    stopInteractive()
                    startAmbience(zone)
                    ambienceStart = clock
                }
            case .ambience:
                if testToPursuit() { return }
                if canLicensed(), clock - ambienceStart > 40 { startLicensed(); return }
                if ambienceZone != zone || !licensed.isPlaying { startAmbience(zone) }
            case .licensed, .splash, .none:
                if testToPursuit() { return }
                if canLicensed() {
                    if type != .licensed || !licensed.isPlaying { startLicensed() }
                } else if type != .ambience || !licensed.isPlaying { startAmbience(zone); ambienceStart = -1000 }
            }
        }
    }

    private func canLicensed() -> Bool { settings.eaTrax && settings.volume > 0 && !world.noLicensed && !songs(fe: false).isEmpty }

    /// Persecución activa o buscando → música interactiva [D: TestToPursuit]. En pantalla partida no hay proyecto interactivo.
    private func testToPursuit() -> Bool {
        guard settings.interactive, settings.volume > 0, !world.splitScreen, world.pursuit != .inactive, !interactive.isEmpty else { return false }
        licensed?.stop(fadeMs: 250)
        currentSong = nil
        type = .interactive
        interactiveStart = clock
        flow.initFlow(topSpeedMPH: world.topSpeedMPH)
        trace?("tipo → INTERACTIVE (\(interactive[interactiveIndex].project.name))")
        return true
    }

    private func stopInteractive() {
        guard type == .interactive else { return }
        interactive[safe: interactiveIndex]?.stop(fadeMs: 400)
        flow.reset()
        // Al volver a las canciones, el siguiente proyecto interactivo [D: SwapInteractiveProjects]
        interactiveIndex = (interactiveIndex + 1) % max(1, interactive.count)
        type = .none
    }

    /// Manda un evento de MusicFlow (10–15, 17) al proyecto interactivo activo [D: PFXMAP].
    func sendFlowEvent(_ n: Int) {
        guard let t = interactive[safe: interactiveIndex] else { return }
        let ids: [Int: Int] = [9: 0x02C3FA91, 10: 0x02C0DC6F, 11: 0x02E9222F, 12: 0x02518C15, 13: 0x02B39639, 14: 0x02E2814E, 15: 0x024C6876, 17: 0x026E7282, 18: 0x0290B6DC]
        guard let id = ids[n] else { return }
        trace?("MusicFlow → evento \(MusicFlow.eventName(n))")
        t.event(id)
    }

    // MARK: EA Trax

    /// Canciones permitidas aquí: ajuste del jugador o DefPlay del juego [V: FE / IG / AL].
    func songs(fe: Bool) -> [MusicSong] {
        guard let lib else { return [] }
        return lib.songs.filter { s in
            let m = settings.playlist[String(s.index)] ?? s.defPlay
            return m == "AL" || m == (fe ? "FE" : "IG")
        }
    }

    /// Al pasar de menús a juego (o al revés): si la canción no está en la lista nueva, se cambia.
    private func songFitsPlace(_ fe: Bool) {
        guard type == .licensed, let s = currentSong else { return }
        if !songs(fe: fe).contains(where: { $0.index == s.index }) { licensed?.stop(fadeMs: 1500); trace?("la canción no es de esta lista: siguiente") }
    }

    /// Siguiente canción sin repetir hasta agotar la lista [D: GenNextMusicTrackID].
    private func nextSong(fe: Bool) -> MusicSong? {
        let list = songs(fe: fe)
        guard !list.isEmpty else { return nil }
        var left = playBits[fe] ?? []
        left = left.intersection(list.map(\.index))
        if left.isEmpty { left = Set(list.map(\.index)); if list.count > 1, let last = lastSong[fe] { left.remove(last) } }
        let pick: Int
        if settings.shuffle { let arr = left.sorted(); pick = arr[Int(rng.next() % UInt64(arr.count))] }
        else { let last = lastSong[fe] ?? -1; pick = left.sorted().first { $0 > last } ?? left.min()! }
        left.remove(pick)
        playBits[fe] = left
        lastSong[fe] = pick
        return list.first { $0.index == pick }
    }

    private func startLicensed() {
        guard let licensed else { return }
        let fe: Bool
        if case .game = world.place { fe = false } else { fe = true }
        guard let s = nextSong(fe: fe) else { return }
        stopInteractive()
        licensed.stop(fadeMs: type == .ambience ? 1500 : 60)
        licensed.event(s.pathEvent)
        type = .licensed; currentSong = s; ambienceZone = -1
        log("Música: ♪ \(s.artist) – \(s.title)")   // el juego lo enseña en el rótulo («chyron») [D: NotifyChyron]
        trace?("tipo → LICENCED: \(s.artist) – \(s.title) (\(s.defPlay))")
    }

    private func startAmbience(_ zone: Int) {
        guard let lib, let licensed, let id = lib.ambienceEvents[zone] else { return }
        if type == .licensed { licensed.stop(fadeMs: 1500) }
        licensed.setVar(named: "ambstate", type == .ambience && licensed.isPlaying ? 1 : 0)
        licensed.event(id)
        type = .ambience; currentSong = nil; ambienceZone = zone
        trace?("tipo → AMBIENCE zona \(zone)")
    }

    // MARK: MusicTrackDelegate

    func musicCallback(_ track: MusicTrack, id: Int, param: Int) {
        switch id {
        case 1: trace?("fin de canción")                                         // el juego elige la siguiente al pararse la pista
        case 2:                                                                  // InteractiveDone [D: MessageDone → Reset]
            trace?("InteractiveDone")
            flow.reset()
            ambienceStart = clock
        case 3:                                                                  // Swap: golpe de MW_MUSIC del proyecto [D: EVT_SWAP1/2]
            let ev = 50 + interactiveIndex * 2 + (param & 1)
            if let e = lib?.licensed.events[safe: ev] { licensed?.event(e.id) }
        default: break
        }
    }

    func musicPart(_ track: MusicTrack, partNode: Int) {
        guard type == .interactive, track === interactive[safe: interactiveIndex] else { return }
        let names = ["ENDPAUSE_1", "LOSE", "ELUDE", "WIN", "NEUTRAL", "WIN_END", "LOSE_END", "ELUDE_END", "END_PAUSE_2"]
        guard let name = track.project.parts.first(where: { $0.value == partNode })?.key, let part = names.firstIndex(of: name) else { return }
        flow.newPart(part)
    }

    // MARK: Pruebas

    var licensedTrack: MusicTrack? { licensed }
    var interactiveTrack: MusicTrack? { interactive[safe: interactiveIndex] }
    func setInteractiveProject(_ i: Int) { interactiveIndex = max(0, min(interactive.count - 1, i)) }
    func setTrace(_ f: ((String) -> Void)?) { trace = f; licensed?.trace = f; for t in interactive { t.trace = f } }
}

extension Array {
    subscript(safe i: Int) -> Element? { i >= 0 && i < count ? self[i] : nil }
}

/// Speech/MusicFlow.cpp [D], línea a línea donde se puede. Se actualiza a 30 Hz.
final class MusicFlow {
    enum State: String { case transition, waiting, neutral, lose, win, elude, terminal }
    weak var system: MusicSystem?
    private(set) var state: State = .transition
    private var startDelay = false
    private var timer: Double = 0          // reloj del estado (s)
    private var elapsed: Double = 0
    private var busy = 0
    private(set) var intensity: Float = 0
    private var avgPlayerSpeed: Float = 0
    private var avgPursuitDist: Float = 0
    private(set) var currentPart = -1
    private var restrained = true
    private var topSpeed: Float = 160
    private var boostTimer: Double = -100
    private var now: Double = 0

    var control: Int { Int(intensity * 127) }
    /// SoundAI::IsMusicActive [I]: hasta que el flujo vuelve a «transición» (InteractiveDone o fin).
    var musicActive: Bool { state != .transition }

    static func eventName(_ n: Int) -> String {
        ["9": "EVT_STOP", "10": "EVT_NEUTRAL", "11": "EVT_LOSE", "12": "EVT_WIN", "13": "EVT_ELUDE", "14": "EVT_ENDWIN", "15": "EVT_ENDBUSTED", "17": "EVT_START", "18": "EVT_INITSWAP"][String(n)] ?? "\(n)"
    }

    /// MessageInitFlow [D].
    func initFlow(topSpeedMPH: Float) {
        reset()
        setState(.waiting)
        topSpeed = topSpeedMPH > 0 ? topSpeedMPH : 160
        timer = now
        startDelay = true
    }

    /// Reset [D].
    func reset() {
        timer = now; elapsed = 0; intensity = 0; avgPlayerSpeed = 0; avgPursuitDist = 0
        restrained = true; state = .transition; currentPart = -1; busy = 0
    }

    private func setState(_ s: State) {
        if s != state { system?.trace?("MusicFlow: \(state.rawValue) → \(s.rawValue)") }
        state = s
    }

    /// MessageNewPart [D].
    func newPart(_ part: Int) {
        currentPart = part
        switch part {
        case 4: setState(.neutral)
        case 1: setState(.lose)
        case 3: setState(.win)
        case 2: setState(.elude)
        case 5, 6, 7, -1, 0, 8: setState(.terminal)
        default: break
        }
    }

    private func updateIntensity(_ adj: Float) { intensity = max(0, min(1, intensity * 0.99 + adj * 0.01)) }

    /// MusicFlow::Update [D].
    func update(_ w: MusicWorld, settings: MusicSystem.Settings) {
        now += 1.0 / 30
        if settings.volume == 0 || !settings.interactive { if state != .transition { reset() }; return }
        if state != .transition {
            elapsed = now - timer
            avgPlayerSpeed = avgPlayerSpeed * 0.95 + w.playerSpeedMPH * 0.05
            avgPursuitDist = avgPursuitDist * 0.97 + (w.pursuitDistance > 0 ? w.pursuitDistance : avgPursuitDist) * 0.03
        }
        switch state {
        case .neutral: neutral(w)
        case .lose: lose(w)
        case .win: win(w)
        case .elude: elude(w)
        case .terminal: terminal()
        case .waiting:
            if startDelay && elapsed > 0.5 { startDelay = false; system?.sendFlowEvent(17) }
        case .transition: break
        }
    }

    private func neutral(_ w: MusicWorld) {
        let cooldown = w.cooldown
        busy = cooldown ? 0 : ((elapsed < 30 || restrained) ? busy : 0)
        updateIntensity(avgPursuitDist < 32 ? 1 : 0)
        updateIntensity(w.timeLastCrashed >= 2.5 ? intensity : 1)
        updateIntensity(w.timeLastNailedCop >= 2.5 ? intensity : 1)
        if restrained { intensity = min(intensity, 0.5) }
        if w.pursuit == .inactive { changeState(.terminal, w); return }
        if restrained && !cooldown {
            if elapsed <= 30 { return }      // ai->GetFocus() != 2: sin «foco» de la cámara en la policía [I]
            restrained = cooldown; intensity = 1; timer = now
        }
        if w.playerSpeedMPH < topSpeed * 0.125 {
            if w.collapseActive { intensity = 0.86; changeState(.lose, w); return }
            if w.pursuit == .searching && w.perpLostTime > 4 && w.timeLastCrashed > 4 { changeState(.elude, w); return }
        }
        if busy != 0 || w.pursuit == .inactive { return }
        if cooldown {
            changeState(w.playerSpeedMPH >= topSpeed * 0.35 ? .win : .elude, w)
        } else {
            if avgPlayerSpeed < topSpeed * 0.125 && w.pursuit == .searching { changeState(.elude, w); return }
            if avgPlayerSpeed > topSpeed * 0.5 { changeState(.win, w); return }
            if avgPursuitDist >= 32 { return }
            changeState(.lose, w); intensity = 0.35
        }
    }

    private func lose(_ w: MusicWorld) {
        busy = elapsed < 45 ? busy : 0
        if w.pursuit == .inactive { changeState(.terminal, w); return }
        if w.playerSpeedMPH < topSpeed * 0.125 && w.timeUntilBusted > 0.5 && w.highIntensity { intensity = 1 }
        else {
            if intensity >= 0.93 { intensity = 0.8 }
            updateIntensity(w.playerSpeedMPH < topSpeed * 0.375 ? 0.86 : 0)
            updateIntensity(w.timeLastCrashed >= 2.5 ? intensity : 0.86)
            updateIntensity(w.timeLastNailedCop >= 2.5 ? intensity : 0.86)
        }
        if (w.pursuit == .searching || w.cooldown) && w.perpLostTime > 4 {
            changeState(w.playerSpeedMPH < topSpeed * 0.35 ? .elude : .win, w); intensity = 1
        } else {
            if busy != 0 { return }
            if avgPlayerSpeed <= topSpeed * 0.5 && w.perpLostTime <= 5 && elapsed <= 90 { return }
            changeState(.neutral, w); intensity = 0.65
        }
    }

    private func win(_ w: MusicWorld) {
        busy = elapsed < 45 ? busy : 0
        updateIntensity(avgPlayerSpeed > topSpeed * 0.5 ? 1 : 0)
        if w.timeLastCrashed < 2 || w.timeLastNailedCop < 2 { intensity = 0.25 }
        if w.timeLastCrashed > 10 && w.timeLastNailedCop > 10 && w.playerSpeedMPH > topSpeed * 0.8, now - boostTimer > 10 {
            intensity = min(1, intensity * 1.15); boostTimer = now
        }
        if w.pursuit == .inactive { changeState(.terminal, w); return }
        if w.playerSpeedMPH < topSpeed * 0.125 && w.collapseActive { changeState(.lose, w); return }
        if avgPlayerSpeed < topSpeed * 0.125 && (w.pursuit == .searching || w.cooldown) { changeState(.elude, w); return }
        if busy != 0 || elapsed <= 90 { return }
        changeState(.neutral, w)
    }

    private func elude(_ w: MusicWorld) {
        busy = elapsed < 5 ? busy : 0
        if w.pursuit == .inactive { changeState(.terminal, w); return }
        updateIntensity(avgPlayerSpeed > 10 ? 1 : 0)
        if w.pursuit == .active {
            if w.pursuitDistance >= 0 && w.pursuitDistance <= 50 { changeState(.lose, w); return }
            changeState(.neutral, w); intensity = 0.8; return
        }
        if avgPlayerSpeed > topSpeed * 0.45 { changeState(.win, w) }
    }

    private func terminal() {
        switch currentPart { case 5, 6, 7: break; default: reset(); system?.trace?("MusicFlow: fin (parte \(currentPart)) → reinicio") }
    }

    /// ChangeStateTo [D]: espera a la parte nueva y manda el evento (10 NEUTRAL, 11 LOSE, 12 WIN, 13 ELUDE, 14 ENDWIN).
    /// Con arresto, EVT_ENDBUSTED (15) [I: lo manda otra parte del juego al detener al jugador].
    private func changeState(_ s: State, _ w: MusicWorld) {
        guard s != state else { return }
        setState(.waiting)
        timer = now; elapsed = 0
        busy = 1
        var ev = -1
        switch s {
        case .neutral: if currentPart != 4 { ev = 10 }
        case .lose: if currentPart != 1 { ev = 11 }
        case .win: if currentPart != 3 { ev = 12 }
        case .elude: avgPlayerSpeed = 0; if currentPart != 2 { ev = 13 }
        case .terminal: if !(5...7).contains(currentPart) { ev = w.busted ? 15 : 14 }
        default: break
        }
        if ev >= 0 { system?.sendFlowEvent(ev) }
        // Si la música ya está en esa parte no llegará aviso nuevo: el estado se pone ya
        if ev < 0 { setState(s) }
    }
}
