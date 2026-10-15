// Director de las películas: cola, cuándo suena cada una y paso por fotograma dentro del motor.
//
// Mientras hay película, `Engine.frame` le cede el fotograma entero (Movies.shared.frame → true): la simulación, el HUD y
// los ganchos del motor se paran, el sonido del juego calla y la música (MusicSystem) se detiene, como hacía el juego
// («Is Movie Playing» / «NIS Play Mute» del mapa de mezcla, ESndGameState FMV [D]). Se salta con Start / ✕ / Intro / Esc.
//
// Cuándo sale cada una (doc 22 §13):
//   · Arranque [D: FEBootFlowManager sBootFlowPAL]: EALOGO (no se salta) → PSA → ATTRACT_MOVIE → «Pulsa START».
//     En «Pulsa START», 30 s sin tocar nada vuelve a la demo [D: SplashScreenMovieTimeout 30 · DoAttract].
//   · Carrera profesional nueva [D: FEAnyMovieScreen::PlaySafehouseIntroMovie → SafeHouseRivalBio → uiRepSheetRivalFlow etapa 5]:
//     STORYFMV_SAF25 y luego BLACKLIST_15 (presentación del primer rival). El prólogo «D-Day» (16.x) aún no está en el port.
//   · Rival vencido [D: uiRepSheetRivalFlow::Next etapa 5–6]: BLACKLIST_<nuevo bin> (el siguiente rival) y, al llegar al bin 13
//     por primera vez, STORYFMV_RAP30 (la ficha policial, SetHasRapSheet).
//   · Pruebas con IntroMovie / OutroMovie [V: gameplay.json]: 1.5.2 → STORYFMV_BLA134, 1.8.1 (persecución épica) → STORYFMV_HER136,
//     16.1.0 → RAC01, 16.2.1 → PIN11 / BUS12, 16.2.2 → CRO06_COH06A, 16.2.3 → RAZ08, desafío de peaje 19.8.32 → TOLLBOOTH_TUTORIAL.
//   · Tutoriales [D: InGameAnyTutorialScreen + CareerSettings HasDone*Tutorial]: la primera prueba de aceleración, radar o peaje
//     de la carrera; la primera persecución (PURSUIT) y la primera recompensa (BOUNTY) [H: el disparo exacto no está en la decomp].
import Foundation
import Metal

final class Movies {
    static let shared = Movies()

    struct Settings: Codable { var enabled = true; var intro = true }
    private(set) var settings = Settings()
    private(set) var library: MovieLibrary?
    private var triedRoot: URL?
    private var renderer: MovieRenderer?
    private(set) var player: MoviePlayer?
    private var queue: [(name: String, then: (() -> Void)?)] = []
    private var currentThen: (() -> Void)?
    private var prevKeys = Set<UInt16>()
    private var warned = false
    private var splashIdle: Double = 0
    /// Momentos del juego (historia, tutoriales, pruebas) activos: solo en la app con ventana (App.swift lo enciende);
    /// las pruebas sin ventana de carreras y carrera profesional no se paran con películas.
    var gameMoments = false
    /// Lo que se ha reproducido (pruebas y registro).
    private(set) var history: [String] = []
    var log: (String) -> Void = { print($0) }

    private init() {
        if let d = try? Data(contentsOf: LightBar.settingsURL),
           let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let r = root["movies"],
           let raw = try? JSONSerialization.data(withJSONObject: r), let s = try? JSONDecoder().decode(Settings.self, from: raw) { settings = s }
        let a = CommandLine.arguments
        if a.contains("--no-movies") { settings.enabled = false }
        if a.contains("--skip-intro") { settings.intro = false }
    }

    /// ¿Hay una película en pantalla (o cargándose)?
    var isPlaying: Bool { player != nil || !queue.isEmpty }

    func setEnabled(_ on: Bool) { settings.enabled = on; save() }
    func setIntro(_ on: Bool) { settings.intro = on; save() }
    private func save() {
        let url = LightBar.settingsURL
        var root = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        root["movies"] = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))) ?? [:]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    /// Carga movies.json (una vez por carpeta de datos). `language`: idioma de la interfaz («spanish»…).
    @discardableResult
    func prepare(root: URL, language: String? = nil) -> MovieLibrary? {
        if triedRoot != root {
            triedRoot = root
            library = MovieLibrary(root: root, language: language)
            if let l = library {
                log("Películas: \(l.movies.count) en movies.json · idioma \(l.language) · " + (l.isoAvailable ? "ISO \(l.isoURL!.lastPathComponent)" : "sin ISO: \(l.isoProblem ?? "")"))
            }
        }
        return library
    }

    // MARK: Cola

    /// Reproduce `name` (después de lo que haya en cola) y luego `then`. Sin ISO, sin la película o apagadas: `then` enseguida.
    func play(_ name: String, then: (() -> Void)? = nil) {
        guard settings.enabled, let lib = library, lib.info(name) != nil, lib.isoAvailable else {
            if !warned, settings.enabled, let lib = library, !lib.isoAvailable {
                warned = true; log("Películas: no se reproducen (\(lib.isoProblem ?? "sin ISO")); el juego sigue sin ellas")
            }
            then?(); return
        }
        queue.append((name.uppercased(), then))
    }

    func playSequence(_ names: [String], then: (() -> Void)? = nil) {
        guard let last = names.last else { then?(); return }
        for n in names.dropLast() { play(n) }
        play(last, then: then)
    }

    /// Quita lo que haya y corta la actual (sin llamar a sus `then`).
    func cancelAll() { queue.removeAll(); player?.stop(); player = nil; currentThen = nil }

    private func startNext() -> Bool {
        guard player == nil, !queue.isEmpty, let lib = library else { return player != nil }
        let q = queue.removeFirst()
        guard let info = lib.info(q.name) else { q.then?(); return startNext() }
        player = MoviePlayer(info: info, library: lib)
        currentThen = q.then
        history.append(info.name)
        log("Película: \(info.name) (\(lib.audioLanguage(info)), \(String(format: "%.1f", info.video.duration)) s)")
        return true
    }

    private func endCurrent() {
        player?.stop(); player = nil
        let t = currentThen; currentThen = nil
        t?()
    }

    // MARK: Por fotograma (Engine.frame)

    /// Si hay película, la dibuja en `target` y devuelve true (el motor no hace nada más este fotograma).
    func frame(engine: Engine, cb: MTLCommandBuffer, target: MTLTexture, dt: Float) -> Bool {
        if player == nil && queue.isEmpty {
            watchSplash(engine, dt: dt)
            if queue.isEmpty { prevKeys = engine.keys; return false }
        }
        guard startNext(), let p = player else { prevKeys = engine.keys; return false }
        p.update()
        // Salto: Start / ✕ (A) en el mando, Intro / Espacio / Esc en el teclado
        let pads = Controllers.shared.pollMenu()
        let pressed = engine.keys.subtracting(prevKeys)
        prevKeys = engine.keys
        let keySkip = pressed.contains(Key.escape.rawValue) || pressed.contains(36) || pressed.contains(Key.space.rawValue)
        if (keySkip || pads.start || pads.accept), p.canSkip() {
            log("Película saltada: \(p.name) a los \(String(format: "%.1f", p.clock)) s")
            for k in [Key.escape.rawValue, 36, Key.space.rawValue] { engine.keys.remove(k) }   // que la interfaz no lo vea al volver
            p.finish()
        }
        SFXWorld.shared.mixer?.muted = true   // el sonido del juego calla durante la película (vuelve en el siguiente fotograma del juego)
        MusicSystem.shared.setMoviePlaying(true)   // la música espera donde estaba («Is Movie Playing» del mapa de mezcla [D])
        if renderer == nil { renderer = MovieRenderer(device: engine.device) }
        renderer?.encode(cb, target: target, image: p.current?.image, subtitle: p.subtitle)
        if p.isDone { endCurrent() }
        return true
    }

    /// «Pulsa START»: 30 s sin tocar nada → demo (ATTRACT_MOVIE) [D: SplashScreen, SplashScreenMovieTimeout].
    private func watchSplash(_ e: Engine, dt: Float) {
        guard settings.enabled, player == nil, queue.isEmpty, let ui = e.ui, ui.state == .splash else { splashIdle = 0; return }
        if !e.keys.isEmpty { splashIdle = 0; return }
        splashIdle += Double(dt)
        if splashIdle > 30 {
            splashIdle = 0
            if library == nil { prepare(root: e.data.root, language: ui.assets.language) }
            play("ATTRACT_MOVIE")
        }
    }

    // MARK: Momentos del juego

    /// Arranque de la app: EALOGO → PSA → ATTRACT_MOVIE [D: sBootFlowPAL]. `--skip-intro` o settings.movies.intro = false: nada.
    func playBoot(root: URL, language: String?, then: (() -> Void)? = nil) {
        prepare(root: root, language: language)
        guard settings.intro else { then?(); return }
        playSequence(["EALOGO", "PSA", "ATTRACT_MOVIE"], then: then)
    }

    /// ¿Ya se vio esta película en la partida? (CareerSave.moviesSeen)
    private func seen(_ name: String) -> Bool { Career.shared.save.moviesSeen?.contains(name) ?? false }
    private func markSeen(_ name: String) {
        Career.shared.modifySave { s in var l = s.moviesSeen ?? []; if !l.contains(name) { l.append(name) }; s.moviesSeen = l }
    }

    /// Carrera profesional nueva: introducción del refugio y del primer rival [D: PlaySafehouseIntroMovie, RivalFlow etapa 5].
    func careerNewGame() {
        guard gameMoments else { return }
        playSequence(["STORYFMV_SAF25", "BLACKLIST_15"])
        markSeen("STORYFMV_SAF25"); markSeen("BLACKLIST_15")
    }

    /// Continuar la partida: si el rival actual aún no se presentó (partidas de antes de las películas), se presenta.
    func careerContinue(bin: Int) {
        guard gameMoments else { return }
        guard bin >= 1 && bin <= 15 else { return }
        let n = String(format: "BLACKLIST_%02d", bin)
        if !seen(n) { play(n); markSeen(n) }
    }

    /// Rival vencido: presentación del siguiente y, al llegar al 13, la ficha policial (una vez) [D: uiRepSheetRivalFlow::Next].
    func rivalDefeated(newBin: Int) {
        guard gameMoments else { return }
        guard newBin >= 1 else { return }
        let n = String(format: "BLACKLIST_%02d", newBin)
        play(n); markSeen(n)
        if newBin == 13 && !seen("STORYFMV_RAP30") { play("STORYFMV_RAP30"); markSeen("STORYFMV_RAP30") }
    }

    /// Antes de empezar una prueba de la carrera: su IntroMovie [V] y, la primera vez, el tutorial de su tipo [D: HasDone*Tutorial].
    func raceStarting(eventId: String, collection: String, kind: RaceEvent.Kind, career: Bool) {
        guard career, gameMoments, let lib = library else { return }
        let m = lib.raceMovies(eventId).intro ?? lib.raceMovies(collection).intro
        var tut: String?
        switch kind {
        case .drag: tut = "DRAG_TUTORIAL"
        case .speedtrap: tut = "SPEEDTRAP_TUTORIAL"
        case .tollbooth: tut = "TOLLBOOTH_TUTORIAL"
        default: break
        }
        if let t = tut, m != t, !seen(t) { play(t); markSeen(t) }
        if let m { play(m); markSeen(m) }
    }

    /// Al ganar una prueba de la carrera con OutroMovie [V] (16.2.1 → STORYFMV_BUS12).
    func raceFinished(eventId: String, collection: String, won: Bool, career: Bool) {
        guard career, won, gameMoments, let lib = library, let m = lib.raceMovies(eventId).outro ?? lib.raceMovies(collection).outro else { return }
        play(m); markSeen(m)
    }

    /// Primera persecución / primera recompensa de la carrera: sus tutoriales (una vez) [H].
    func careerPursuitStarted() { if gameMoments, !seen("PURSUIT_TUTORIAL") { play("PURSUIT_TUTORIAL"); markSeen("PURSUIT_TUTORIAL") } }
    func careerBountyEarned() { if gameMoments, !seen("BOUNTY_TUTORIAL") { play("BOUNTY_TUTORIAL"); markSeen("BOUNTY_TUTORIAL") } }
}
