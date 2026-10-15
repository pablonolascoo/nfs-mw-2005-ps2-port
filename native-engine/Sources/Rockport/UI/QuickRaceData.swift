// Datos de la carrera rápida: lista de pruebas por tipo y zona (UIQRTrackSelect::BuildPresetTrackList [D]), coches elegibles
// (UIQRCarSelect: listas de serie, carrera y bonificación [D]) y los ajustes (FEDatabase::QuickRaceSettings [D]).
//
// Desbloqueos [I: UnlockSystem no está en los datos convertidos]:
//   - Pruebas: las marcadas AvailableQR en la base del juego [V] más las de los bins cuyo rival ya se ha vencido en la carrera
//     profesional (save.json) y las ganadas en ella. Las bloqueadas se ven con el candado y el texto del juego «Desbloquea esta
//     pista al derrotar a %s, miembro %d de la Blacklist» (0xBD563BE5) [D].
//   - Coches de serie: los pvehicle con PlayerUsable [V: physics.json] y modelo convertido. Se desbloquean con
//     frontend.UnlockedAt (GLOBAL\FE_ATTRIB.BIN → fe-cameras.json [V]): libre si el bin actual de la carrera es ≤ UnlockedAt;
//     si no, el texto «derrota a … nº UnlockedAt+1» (0x4EF2A115) [D: UIQRCarSelect::RefreshHeader]. Marca: frontend.manufacturer.
//   - Bonificación: coches de la Lista Negra (presets BL2…BL15 y RAZORMUSTANG), bloqueados hasta vencer a su rival (0x4EF2A115),
//     y los cuatro de premio (SL65, 911 GT2, M3 GTR de la demo E3, Corvette C6.R) con sus textos 0xBD8BAC91…94 [D:
//     GetBonusUnlockText]; su regla exacta (UnlockSystem) no está en los datos [I: serie desafío y carrera completas].
import Foundation
import simd

/// Un coche elegible en Car_Select.
struct QRCar {
    enum List: Int { case stock = 0, career = 1, bonus = 3 }
    /// Nombre del preset (presets.json) o del modelo de serie (cars/<MODELO>.glb).
    let id: String
    let model: String
    let preset: String?
    var list: List
    var locked: Bool
    /// Bin del rival que lo desbloquea (coches de la Lista Negra) o UnlockedAt + 1 (de serie).
    var unlockBin: Int?
    /// De serie: bin a partir del cual se puede usar (frontend.UnlockedAt).
    var unlockedAt: Int? = nil
    /// Premio: texto del juego (0xBD8BAC91…94) y regla [I].
    var bonusText: UInt32? = nil
    /// Nombre en el idioma del disco (CARNAME_<MARCA>_<colección> [D: FECarRecord::GetNameHash]) o el del modelo.
    let name: String
    /// Logotipo SECONDARY_LOGO_<colección> [D: GetLogoHash]; GENERIC_LOGO_256 si no hay.
    let logo: UInt32
    /// Valores de las barras (0…1): aceleración, punta y manejo [I: Physics::Info::EstimatePerformance no está decompilado].
    var stats = SIMD3<Float>(0.5, 0.5, 0.5)
}

/// Una prueba en Track_Select.
struct QRTrack {
    let event: RaceEvent
    let locked: Bool
    let bin: Int
}

/// QuickRaceSettings: lo que el jugador elige en las pantallas (se guarda en settings.json, clave «quickRace»).
struct QRSettings: Codable {
    var mode: String = "circuit"            // RaceEvent.Kind.rawValue
    /// RegionFilterBits: 0 universitaria, 1 costera, 2 ciudad, 3 todas [D: hashes 0xA6850651, 0xA5C20E7D, 0x8663FAEF, 0x632DD19B].
    var region = 3
    var eventByMode: [String: String] = [:]
    var laps = 2
    /// TrafficDensity 0…3: ninguno, mínimo, moderado, máximo.
    var traffic = 1
    var opponents = 3
    /// Rivales de la IA en pantalla partida (extensión; el juego no pone ninguno: SetNumOpponents(1) = el otro jugador [D]).
    var splitOpponents = 0
    /// AISkill 0…2: fácil, medio, difícil.
    var skill = 1
    var catchUp = true
    /// Extensión del port: la carrera rápida del juego quita siempre la policía (SetCopsEnabled(false) [D]).
    var police = false
    var reverse = false
    var cars: [String] = []

    static let regions = ["college", "coastal", "city"]
    static let regionNames: [UInt32] = [0xA6850651, 0xA5C20E7D, 0x8663FAEF, 0x632DD19B]
    /// Densidad de tráfico por nivel [I: el juego la pasa a FillCustomRace sin decompilar].
    static let trafficDensity: [Float] = [0, 0.25, 0.55, 1.0]
}

enum QuickRaceData {
    /// Nombres de marca del juego (FECarRecord::GetManufacturerName [D]).
    static let manufacturers = ["BMW", "FORD", "SUBARU", "PORSCHE", "AUDI", "MAZDA", "GENERAL_MOTORS", "DODGE", "TOYOTA", "MITSUBISHI",
                                "MCLAREN", "MERCEDES", "NISSAN", "LOTUS", "LAMBORGHINI", "RENAULT", "LEXUS", "PONTIAC", "CHEVROLET",
                                "VAUXHALL", "ASTONMARTIN", "VOLKSWAGEN", "FIAT", "CADILLAC", "CORVETTE"]

    /// Icono de tipo de prueba (texturas de MSOption [D][V]).
    static func modeIcon(_ k: RaceEvent.Kind) -> UInt32 {
        switch k {
        case .circuit: 0xE9638D3E; case .sprint: 0x2521E5EB; case .drag: 0xAAAB31E9
        case .knockout: 0x3A015595; case .speedtrap: 0x66C9A7B6; case .tollbooth: 0x1A091045; case .challenge: 0x2A49B5E2
        }
    }
    /// Nombre del tipo de prueba (MSOption [D]).
    static func modeName(_ k: RaceEvent.Kind) -> UInt32 {
        switch k {
        case .circuit: 0x034FA2C1; case .sprint: 0xB94FD70E; case .drag: 0x6F547E4C
        case .knockout: 0x4930F5FC; case .speedtrap: 0xEE1EDC76; case .tollbooth: 0xA15E4505; case .challenge: 0x25BBD4C3
        }
    }
    /// Título de Track_Select (UIQRTrackSelect::Setup [D]) y cabecera de Track_Options (UIQRTrackOptions::Setup [D]).
    static func trackSelectTitle(_ k: RaceEvent.Kind) -> UInt32 {
        switch k {
        case .circuit: 0x3DE80A85; case .drag: 0x136C5C90; case .knockout: 0xD6D65640; case .sprint: 0xC2D85652
        case .tollbooth: 0xE3AFADC9; case .speedtrap: 0x3070453A; case .challenge: 0x3DE80A85
        }
    }
    static func optionsTitle(_ k: RaceEvent.Kind) -> UInt32 {
        switch k {
        case .circuit: 0xA6ED015D; case .drag: 0xEC86E188; case .knockout: 0x0CC959B8; case .sprint: 0xB80BFC8A
        case .tollbooth: 0x141EDFE1; case .speedtrap: 0xF2745852; case .challenge: 0xA6ED015D
        }
    }

    /// Colección «frontend» de cada coche (CARNAME_<marca>_<colección>, SECONDARY_LOGO_<colección>) cuando no se llama como
    /// su pvehicle [V: búsqueda por hash en los textos y texturas del disco].
    static let feAlias: [String: String] = ["A3": "A3_20T", "A4": "A4_32", "CARRERAGT": "CARRERA_GT", "BMWM3GTR": "M3_GTR",
                                            "BMWM3GTRE46": "M3_GTRE46", "IMPREZAWRX": "IMPREZZAWRX", "CORVETTE": "CORVETTE_CAR"]
    /// Nombres que no están en la tabla de textos del disco con esa clave [I: nombres comerciales].
    static let fallbackNames: [String: String] = ["BMWM3GTRE46": "BMW M3 GTR", "BMWM3GTR": "BMW M3 GTR", "IMPREZAWRX": "Subaru Impreza WRX STi",
                                                  "RX8": "Mazda RX-8", "RX7": "Mazda RX-7", "GTO": "Pontiac GTO", "CLK500": "Mercedes-Benz CLK 500",
                                                  "CORVETTE": "Chevrolet Corvette C6", "CARRERAGT": "Porsche Carrera GT", "MUSTANGGT": "Ford Mustang GT"]

    // MARK: Pruebas

    /// BuildPresetTrackList [D]: bins 21 y 15…1, carreras del mundo y del rival, del tipo elegido y de la zona.
    static func tracks(db: RaceDatabase, mode: RaceEvent.Kind, region: Int, save: CareerSave?) -> [QRTrack] {
        var out: [QRTrack] = []
        let defeated = Set(save?.rivalsDefeated ?? []), won = Set(save?.racesWon ?? [])
        for bin in [21] + Array((1...15).reversed()) {
            guard let b = db.bin(bin) else { continue }
            for id in b.worldRaces + b.bossRaces {
                guard let e = db.event(id), e.kind == mode, e.kind != .challenge, !e.challengeSeries else { continue }
                if region < 3, e.region != QRSettings.regions[region] { continue }
                if out.contains(where: { $0.event.id == e.id }) { continue }
                let unlocked = e.availableQuickRace || defeated.contains(bin) || won.contains(e.id)
                out.append(QRTrack(event: e, locked: !unlocked, bin: bin))
            }
        }
        return out
    }

    /// TRACK_MAP_<id con «_»>; «.r» = sentido contrario (TRACK_MAP_x_y_z_R) [V: TrackMaps.bin].
    static func mapTexture(_ e: RaceEvent) -> UInt32 {
        var id = e.eventId.uppercased().replacingOccurrences(of: ".", with: "_")
        if id.hasSuffix("_R") == false, e.id.hasSuffix("_r") { id += "_R" }
        return feHash("TRACK_MAP_" + id)
    }

    /// CalcLanguageHash("TRACKNAME_", race) [D]: «TRACKNAME_15_1_1» (en castellano «Ironwood Estates»).
    static func trackName(_ e: RaceEvent, assets: FEAssets) -> String {
        let id = e.eventId.uppercased().replacingOccurrences(of: ".", with: "_")
        return assets.string(feHash("TRACKNAME_" + id)) ?? assets.string(feHash("TRACKNAME_" + id.replacingOccurrences(of: "_R", with: ""))) ?? e.eventId
    }

    /// Prueba al revés si existe («15.1.1.r») [V: races.json].
    static func reversed(_ e: RaceEvent, db: RaceDatabase) -> RaceEvent? {
        db.events.first { $0.eventId.lowercased() == e.eventId.lowercased() + ".r" }
    }

    // MARK: Coches

    private static var carCache: (URL, [QRCar])?

    /// Coches para la carrera rápida: de serie, el de la carrera profesional y los de la Lista Negra.
    static func cars(data: GameData, assets: FEAssets?, save: CareerSave?) -> [QRCar] {
        let base: [QRCar]
        if let c = carCache, c.0 == data.root { base = c.1 } else { base = buildCars(data: data, assets: assets); carCache = (data.root, base) }
        let defeated = Set(save?.rivalsDefeated ?? [])
        let bin = save?.currentBin ?? 15
        let careerDone = bin == 0 || defeated.contains(1)
        let challenges = save?.challengesDone.count ?? 0
        return base.map { c in
            var c = c
            if let at = c.unlockedAt { c.locked = bin > at }
            else if let t = c.bonusText {
                switch t {
                case 0xBD8BAC91: c.locked = challenges < 68                 // prueba 68 de la serie desafío
                case 0xBD8BAC92: c.locked = challenges < 69                 // toda la serie desafío
                case 0xBD8BAC93: c.locked = !careerDone                     // modo carrera completo
                default: c.locked = !(careerDone && challenges >= 69)       // 100 %
                }
            } else if c.list == .bonus, let b = c.unlockBin { c.locked = !defeated.contains(b) }
            return c
        }
    }

    /// Coches del concesionario de FE_ATTRIB.BIN (fe-cameras.json): coste, UnlockedAt y marca por colección frontend.
    private static func feCars(_ data: GameData) -> [String: (unlockedAt: Int, manufacturer: Int)] {
        guard let d = try? Data(contentsOf: data.url("fe-cameras.json")),
              let js = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let cars = js["cars"] as? [String: [String: Any]] else { return [:] }
        var out: [String: (Int, Int)] = [:]
        for (k, v) in cars { out[k.uppercased()] = ((v["unlockedAt"] as? NSNumber)?.intValue ?? 16, (v["manufacturer"] as? NSNumber)?.intValue ?? 0) }
        return out
    }

    private static func buildCars(data: GameData, assets: FEAssets?) -> [QRCar] {
        var out: [QRCar] = []
        // pvehicle con PlayerUsable [V]; fuera tráfico, policía y los coches de los desafíos (cs_*)
        guard let d = try? Data(contentsOf: data.url("physics.json")),
              let js = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let veh = js["vehicles"] as? [String: [String: Any]] else { return out }
        var seen = Set<String>()
        let fm = FileManager.default
        let fe = feCars(data)
        /// Colección frontend de un modelo: alias conocido o el mismo nombre [V: fe-cameras.json].
        func feColl(_ model: String) -> String { feAlias[model.uppercased()] ?? model.uppercased() }
        func logo(_ coll: String) -> UInt32 {
            for c in [feAlias[coll.uppercased()] ?? coll, coll] {
                let h = feHash("SECONDARY_LOGO_" + c)
                if assets?.hasTexture(h) == true { return h }
            }
            return feHash("GENERIC_LOGO_256")
        }
        func name(_ coll: String, model: String) -> String {
            let fc = feColl(model)
            // Marca de frontend.manufacturer (1 = BMW … 25 = CORVETTE) [D: GetManufacturerName][V]
            if let m = fe[fc]?.manufacturer, m >= 1, m <= manufacturers.count, let s = assets?.string(feHash("CARNAME_\(manufacturers[m - 1])_\(fc)")) { return s }
            for c in [fc, coll, model] {
                for m in manufacturers { if let s = assets?.string(feHash("CARNAME_\(m)_\(c)")) { return s } }
            }
            return fallbackNames[model.uppercased()] ?? model
        }
        /// Coches de premio (FECarRecord con BONUS_*: GetBonusUnlockText [D]).
        let bonus: [String: UInt32] = ["SL65": 0xBD8BAC91, "911GT2": 0xBD8BAC92, "BMWM3GTR": 0xBD8BAC93, "CORVETTEC6R": 0xBD8BAC94]
        let skip: Set<String> = ["speedtest", "wrx_demo", "m3gtre46careerstart", "rx8speedt"]
        for (coll, v) in veh.sorted(by: { $0.key < $1.key }) {
            guard (v["playerUsable"] as? Bool) == true, let model = v["model"] as? String, !model.isEmpty,
                  !coll.hasPrefix("cs_"), !skip.contains(coll), !seen.contains(model),
                  fm.fileExists(atPath: data.url("cars/\(model).glb").path) else { continue }
            seen.insert(model)
            var c = QRCar(id: model, model: model, preset: nil, list: .stock, locked: false, unlockBin: nil,
                          name: name(coll, model: model), logo: logo(coll), stats: stats(v))
            if let f = fe[feColl(model)] { c.unlockedAt = f.unlockedAt; c.unlockBin = f.unlockedAt + 1 }
            else if let t = bonus[model.uppercased()] { c.list = .bonus; c.bonusText = t }
            out.append(c)
        }
        // Carrera: el BMW M3 GTR de la historia [V: presets.json M3GTRCAREERSTART]
        if let p = CarPresets.named("M3GTRCAREERSTART", in: data) {
            out.insert(QRCar(id: p.name, model: p.car, preset: p.name, list: .career, locked: false, unlockBin: nil,
                             name: name("bmwm3gtr", model: p.car), logo: logo("M3_GTR"), stats: out.first { $0.model == p.car }?.stats ?? .init(0.8, 0.8, 0.7)), at: 0)
        }
        // Lista Negra (bonificación): BL15 → BL2 y RAZORMUSTANG
        for p in CarPresets.blacklist(data).reversed() {
            guard let bin = p.blacklist else { continue }
            let coll = veh.first { ($0.value["model"] as? String) == p.car && !$0.key.hasPrefix("cs_") }?.key ?? p.car.lowercased()
            let label = (assets?.string(feHash(String(format: "BLACKLIST_RIVAL_%02d_AKA", bin))) ?? p.name) + " · " + name(coll, model: p.car)
            out.append(QRCar(id: p.name, model: p.car, preset: p.name, list: .bonus, locked: true, unlockBin: bin,
                             name: label, logo: logo(coll), stats: out.first { $0.model == p.car }?.stats ?? .init(0.6, 0.6, 0.6)))
        }
        // Barras normalizadas en toda la lista
        func norm(_ k: Int) {
            let vals = out.map { $0.stats[k] }
            guard let lo = vals.min(), let hi = vals.max(), hi > lo else { return }
            for i in out.indices { out[i].stats[k] = 0.15 + 0.85 * (out[i].stats[k] - lo) / (hi - lo) }
        }
        norm(0); norm(1); norm(2)
        return out
    }

    /// Indicadores brutos [I]: aceleración ≈ par máximo / masa, punta ≈ potencia / arrastre, manejo ≈ agarre medio.
    private static func stats(_ v: [String: Any]) -> SIMD3<Float> {
        func num(_ a: Any?) -> Float { (a as? NSNumber)?.floatValue ?? 0 }
        func arr(_ a: Any?) -> [Float] { (a as? [Any])?.map(num) ?? [] }
        let mass = max(500, num(v["mass"]))
        let up = v["upgrades"] as? [String: Any]
        // De serie: las clases del propio pvehicle (las mejoras van aparte en «upgrades»)
        let eng = (v["engine"] as? [String: Any]) ?? (up?["engine"] as? [[String: Any]])?.first ?? [:]
        let tires = (v["tires"] as? [String: Any]) ?? (up?["tires"] as? [[String: Any]])?.first ?? [:]
        let chassis = (v["chassis"] as? [String: Any]) ?? (up?["chassis"] as? [[String: Any]])?.first ?? [:]
        let torque = arr(eng["TORQUE"]).max() ?? 300
        let rpm = num(eng["RED_LINE"]) > 0 ? num(eng["RED_LINE"]) : 7000
        let grip = (arr(tires["DYNAMIC_GRIP"]) + arr(tires["STATIC_GRIP"])).reduce(0, +) / Float(max(1, arr(tires["DYNAMIC_GRIP"]).count + arr(tires["STATIC_GRIP"]).count))
        let drag = max(0.1, num(chassis["DRAG_COEFFICIENT"]))
        return SIMD3(torque / mass, (torque * rpm / drag).squareRoot(), grip > 0 ? grip : 1)
    }

    // MARK: Ajustes

    static func loadSettings() -> QRSettings {
        guard let d = try? Data(contentsOf: LightBar.settingsURL),
              let js = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let q = js["quickRace"],
              let qd = try? JSONSerialization.data(withJSONObject: q),
              let s = try? JSONDecoder().decode(QRSettings.self, from: qd) else { return QRSettings() }
        return s
    }

    /// Guarda solo la clave «quickRace» de settings.json (el resto del archivo no se toca).
    static func saveSettings(_ s: QRSettings) {
        SettingsFile.update(key: "quickRace", value: s)
    }
}

/// settings.json compartido (~/Library/Application Support/Rockport/settings.json): cada parte escribe solo su clave.
enum SettingsFile {
    static func update<T: Encodable>(key: String, value: T) {
        let url = LightBar.settingsURL
        var js = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        guard let d = try? JSONEncoder().encode(value), let obj = try? JSONSerialization.jsonObject(with: d) else { return }
        js[key] = obj
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let out = try JSONSerialization.data(withJSONObject: js, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: url, options: .atomic)
        } catch { fputs("settings.json: no se pudo guardar «\(key)»: \(error)\n", stderr) }
    }

    static func read(key: String) -> Any? {
        (try? Data(contentsOf: LightBar.settingsURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?[key]
    }
}
