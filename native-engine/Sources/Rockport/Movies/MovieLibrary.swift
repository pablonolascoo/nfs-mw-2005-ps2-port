// Catálogo de películas (movies.json, doc 22) y dónde leerlas: directamente de la ISO del jugador, sin copiarlas.
//
// Reglas del juego:
//   · Archivo [D: FEObjectCallbacks.cpp CalculateMovieFilename]: MOVIES\<nombre>_<IDIOMA>_<PAL|NTSC>; si no existe en el
//     idioma del juego, el inglés. En la PAL hay inglés, castellano e italiano (las 64 «_UNKNOWN» del inventario [V]).
//   · Subtítulos [D: SubTitle.cpp SubTitler]: los de los tutoriales siempre; los demás solo si el idioma no es el inglés y el
//     texto de ese idioma no está vacío. En castellano la historia va doblada y su texto está vacío [V]: no salen.
//   · Volumen de cada película [D: MoviePlayer.cpp MovieVolumeArray]: historia 0x50, logo 0x3C, demo 0x41, tutoriales 0x37,
//     aviso PSA 0x32, Lista Negra 0x2D (de 0x7F).
//   · Películas de las pruebas [V: GLOBAL\GAMEPLAY.BIN → gameplay.json, campos IntroMovie / OutroMovie]: se leen al arrancar.
//
// Dónde está la ISO: `install.ok` («iso») de la carpeta de datos · `--iso <ruta>` · ROCKPORT_ISO · `original/<ID>.iso` del repo.
// Si no está, las películas se saltan (aviso una vez) y el juego sigue.
import Foundation

struct MovieCue: Decodable {
    let start: Double
    let end: Double
    let label: String?
    let text: [String: String]?
    let textB: [String: String]?
}

struct MovieSubtitles: Decodable {
    let tutorial: Bool
    let cues: [MovieCue]
}

struct MovieAudioInfo: Decodable {
    let path: String
    let isoOffset: Int
    let size: Int
    let identicalToEnglish: Bool?
}

struct MovieInfo: Decodable {
    let name: String
    let kind: String
    let audioByLanguage: [String: MovieAudioInfo]
    let subtitles: MovieSubtitles?
    struct Video: Decodable { let width: Int; let height: Int; let fps: Double; let frames: Int; let duration: Double }
    let video: Video
}

private struct MoviesFile: Decodable {
    let disc: String?
    let movies: [MovieInfo]
}

final class MovieLibrary {
    let root: URL
    let movies: [String: MovieInfo]
    let disc: String
    /// Idioma del juego (MAYÚSCULAS, como en movies.json): SPANISH, ENGLISH…
    var language: String
    private(set) var isoURL: URL?
    private var iso: Data?
    private(set) var isoProblem: String?

    /// Volumen de cada película (0…0x7F) [D: MovieVolumeArray].
    static let volumeTable: [String: Int] = {
        var t: [String: Int] = ["ATTRACT_MOVIE": 0x41, "DRAG_TUTORIAL": 0x37, "EALOGO": 0x3C, "INTRO_MOVIE": 0x37, "SPRINT_TUTORIAL": 0x37,
                                "TOLLBOOTH_TUTORIAL": 0x37, "BOUNTY_TUTORIAL": 0x37, "PURSUIT_TUTORIAL": 0x37, "SPEEDTRAP_TUTORIAL": 0x37, "PSA": 0x32]
        for i in 1...15 { t[String(format: "BLACKLIST_%02d", i)] = 0x2D }
        for s in ["BLA134", "BUS12", "CRO06_COH06A", "DDA01", "EPI138", "HER136", "PIN11", "POL17_MOT21", "RAP30", "RAZ08", "ROC02", "SAF25", "RAC01"] {
            t["STORYFMV_" + s] = 0x50
        }
        return t
    }()

    init?(root: URL, language: String? = nil) {
        self.root = root
        guard let d = try? Data(contentsOf: root.appendingPathComponent("movies.json")),
              let f = try? JSONDecoder().decode(MoviesFile.self, from: d) else { return nil }
        var m: [String: MovieInfo] = [:]
        for x in f.movies { m[x.name.uppercased()] = x }
        movies = m
        disc = f.disc ?? root.lastPathComponent
        self.language = (language ?? MovieLibrary.uiLanguage(root: root)).uppercased()
        locateISO()
    }

    /// Idioma de la interfaz: el primero de frontend/index.json (el de la ISO; en la PAL «spanish»), o `--lang`.
    static func uiLanguage(root: URL) -> String {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--lang"), i + 1 < a.count { return a[i + 1] }
        if let d = try? Data(contentsOf: root.appendingPathComponent("frontend/index.json")),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let l = j["languages"] as? [String], let f = l.first { return f }
        return "english"
    }

    // MARK: ISO

    private func locateISO() {
        var cands: [URL] = []
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--iso"), i + 1 < a.count { cands.append(URL(fileURLWithPath: (a[i + 1] as NSString).expandingTildeInPath)) }
        if let e = ProcessInfo.processInfo.environment["ROCKPORT_ISO"] { cands.append(URL(fileURLWithPath: e)) }
        if let d = try? Data(contentsOf: root.appendingPathComponent("install.ok")),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let p = j["iso"] as? String { cands.append(URL(fileURLWithPath: p)) }
        // Repositorio: map-data/<ID> → original/<ID>.iso
        cands.append(root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("original/\(disc).iso"))
        let fm = FileManager.default
        for u in cands where fm.fileExists(atPath: u.path) {
            if let d = try? Data(contentsOf: u, options: .alwaysMapped) {   // 4 GB mapeados: no se lee nada hasta usarlo
                iso = d; isoURL = u; return
            }
        }
        isoProblem = cands.isEmpty ? "sin ruta de la ISO" : "no encuentro la ISO (\(cands.map(\.path).joined(separator: " · ")))"
    }

    var isoAvailable: Bool { iso != nil }

    // MARK: Elección de archivo, volumen y subtítulos

    /// Película del juego por nombre (sin distinguir mayúsculas: «storyfmv_bla134» de gameplay.json).
    func info(_ name: String) -> MovieInfo? { movies[name.uppercased()] }

    /// Idioma del archivo: el del juego si existe; si no, inglés [D].
    func audioLanguage(_ m: MovieInfo) -> String {
        m.audioByLanguage[language] != nil ? language : "ENGLISH"
    }

    /// El MPC del idioma elegido, sin copiar (trozo de la ISO mapeada) y con su cabecera comprobada.
    func open(_ m: MovieInfo) throws -> MPCFile {
        guard let iso else { throw NSError(domain: "Movies", code: 1, userInfo: [NSLocalizedDescriptionKey: isoProblem ?? "sin ISO"]) }
        let lang = audioLanguage(m)
        guard let a = m.audioByLanguage[lang] else { throw NSError(domain: "Movies", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(m.name): sin archivo"]) }
        guard a.isoOffset >= 0, a.isoOffset + a.size <= iso.count else {
            throw NSError(domain: "Movies", code: 3, userInfo: [NSLocalizedDescriptionKey: "\(a.path) fuera de la ISO (¿otra ISO?)"])
        }
        let slice = iso.subdata(in: a.isoOffset..<(a.isoOffset + a.size))
        return try MPCFile(data: slice)
    }

    func volume(_ m: MovieInfo) -> Float { Float(MovieLibrary.volumeTable[m.name.uppercased()] ?? 0x50) / 127 }

    /// Frases que se ven en este idioma (regla de SubTitler), con su texto ya elegido; `^` = salto de línea [V].
    func subtitleCues(_ m: MovieInfo) -> [(start: Double, end: Double, text: String)] {
        guard let s = m.subtitles else { return [] }
        let lang = language
        if !s.tutorial && lang == "ENGLISH" { return [] }
        var out: [(Double, Double, String)] = []
        for c in s.cues {
            var lines: [String] = []
            if let t = c.text?[lang], !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines.append(t) }
            if s.tutorial, let t = c.textB?[lang], !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines.append(t) }
            guard !lines.isEmpty else { continue }
            let text = lines.joined(separator: "\n").replacingOccurrences(of: "^", with: "\n")
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
            out.append((c.start, c.end, text))
        }
        return out
    }

    // MARK: Películas de las pruebas (IntroMovie / OutroMovie de GAMEPLAY.BIN)

    private var raceMoviesLoaded = false
    private var intro: [String: String] = [:], outro: [String: String] = [:]

    /// EventID («1.5.2») o nombre de colección → película de entrada / salida [V: gameplay.json].
    func raceMovies(_ key: String) -> (intro: String?, outro: String?) {
        loadRaceMovies()
        return (intro[key], outro[key])
    }

    /// Tabla completa (EventID → entrada / salida), para las pruebas y la documentación.
    func raceMovieTable() -> [(event: String, intro: String?, outro: String?)] {
        loadRaceMovies()
        let keys = Set(intro.keys).union(outro.keys).filter { $0.contains(".") }
        return keys.sorted { $0.split(separator: ".").compactMap { Int($0) }.lexicographicallyPrecedes($1.split(separator: ".").compactMap { Int($0) }) }
            .map { ($0, intro[$0], outro[$0]) }
    }

    private func loadRaceMovies() {
        guard !raceMoviesLoaded else { return }
        raceMoviesLoaded = true
        guard let d = try? Data(contentsOf: root.appendingPathComponent("gameplay.json")),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let cols = j["collections"] as? [[String: Any]] else { return }
        for c in cols {
            guard let v = c["values"] as? [String: Any] else { continue }
            let i = (v["IntroMovie"] as? String).map { $0.uppercased() }, o = (v["OutroMovie"] as? String).map { $0.uppercased() }
            let keys = [v["EventID"] as? String, v["CollectionName"] as? String, v["Name"] as? String].compactMap { $0 }
            for k in keys {
                if let i, movies[i] != nil { intro[k] = i }
                if let o, movies[o] != nil { outro[k] = o }
            }
        }
    }
}
